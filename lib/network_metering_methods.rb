# frozen_string_literal: true

require "ipaddr"
require "json"

# Ships the metering rule set to the VM as config.json and triggers
# apply-metering-config. Rhizome owns the nftables render.
module NetworkMeteringMethods
  CONFIG_PATH = "/etc/pg-metering/config.json"

  INTERNAL_CIDRS = {
    "v4" => %w[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16].freeze,
    "v6" => %w[fc00::/7 fe80::/10].freeze,
  }.freeze

  # No-op on rhizome trees without the metering bins.
  def install_network_metering(provider)
    return unless vm.sshable.cmd("test -x postgres/bin/apply-metering-config && test -x postgres/bin/refresh-network-sets && test -x postgres/bin/export-network-metrics && echo YES || echo NO").strip == "YES"

    vm.sshable.cmd("sudo install -d -m 0755 /etc/pg-metering")
    vm.sshable.write_file(CONFIG_PATH, JSON.generate(network_metering_config(provider)))
    vm.sshable.cmd("sudo /home/ubi/postgres/bin/apply-metering-config")

    render_network_metering_units.each { |path, content| vm.sshable.write_file(path, content) }
    vm.sshable.cmd("sudo systemctl daemon-reload")
    vm.sshable.cmd("sudo systemctl enable pg-metering.service")
    vm.sshable.cmd("sudo systemctl enable --now pg-metering-export.timer pg-metering-refresh.timer")
    # Prime provider sets now; otherwise all traffic hits public_internet
    # until the refresh timer fires.
    vm.sshable.cmd("sudo systemctl start pg-metering-refresh.service || true")
  end

  def network_metering_config(provider)
    {
      "version" => 1,
      "region" => (resource || vm).location.name.sub(/^gcp-/, ""),
      "provider" => provider,
      "rules" => base_rules.sort_by { |r| r["priority"] },
      "provider_config" => {},
    }
  end

  def base_rules
    [
      {"id" => "internal", "priority" => 10, "label" => "internal", "cidrs" => INTERNAL_CIDRS},
      {"id" => "control_plane", "priority" => 20, "label" => "control_plane", "cidrs" => control_plane_cidrs},
      {"id" => "excluded_svc", "priority" => 40, "label" => "excluded", "source" => "provider"},
      {"id" => "intra_region", "priority" => 50, "label" => "intra_region", "source" => "provider"},
      {"id" => "inter_region_t1", "priority" => 61, "label" => "inter_region_t1", "source" => "provider"},
      {"id" => "public_internet", "priority" => 999, "label" => "public_internet", "type" => "catchall"},
    ]
  end

  # 0.0.0.0/0 and ::/0 are the Config defaults; drop those supernets or every
  # packet would be metered as control_plane and downstream billing buckets
  # would go dark.
  def control_plane_cidrs
    cidrs = Config.control_plane_outbound_cidrs.reject { |c| c == "0.0.0.0/0" || c == "::/0" }
    split_ips_by_version(cidrs)
  end

  # nft sets are family-typed; partition v4/v6 before rendering.
  def split_ips_by_version(ips)
    grouped = {"v4" => [], "v6" => []}
    ips.each do |ip|
      grouped[IPAddr.new(ip).ipv4? ? "v4" : "v6"] << ip
    rescue IPAddr::Error => e
      raise "invalid IP entry #{ip.inspect}: #{e.message}"
    end
    grouped
  end

  def render_network_metering_units
    {
      "/etc/systemd/system/pg-metering.service" => <<~UNIT,
        [Unit]
        Description=Load pg network metering nftables table
        After=network-pre.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/home/ubi/postgres/bin/apply-metering-config

        [Install]
        WantedBy=multi-user.target
      UNIT
      "/etc/systemd/system/pg-metering-export.service" => <<~UNIT,
        [Unit]
        Description=Export pg network metering counters to node_exporter textfile

        [Service]
        Type=oneshot
        ExecStart=/home/ubi/postgres/bin/export-network-metrics
      UNIT
      "/etc/systemd/system/pg-metering-export.timer" => <<~UNIT,
        [Unit]
        Description=Schedule pg network metering export

        [Timer]
        OnBootSec=60s
        OnUnitActiveSec=60s

        [Install]
        WantedBy=timers.target
      UNIT
      "/etc/systemd/system/pg-metering-refresh.service" => <<~UNIT,
        [Unit]
        Description=Refresh provider IP range sets for pg network metering
        Wants=network-online.target
        After=network-online.target

        [Service]
        Type=oneshot
        ExecStart=/home/ubi/postgres/bin/refresh-network-sets
      UNIT
      "/etc/systemd/system/pg-metering-refresh.timer" => <<~UNIT,
        [Unit]
        Description=Schedule provider IP range refresh

        [Timer]
        OnBootSec=120s
        OnCalendar=daily
        RandomizedDelaySec=1h
        Persistent=true

        [Install]
        WantedBy=timers.target
      UNIT
    }
  end
end
