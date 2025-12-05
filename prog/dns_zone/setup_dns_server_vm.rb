# frozen_string_literal: true

class Prog::DnsZone::SetupDnsServerVm < Prog::Base
  subject_is :vm, :sshable

  def self.assemble(dns_server_id, name: nil, vm_size: "standard-2", storage_size_gib: 30, location_id: Location::HETZNER_FSN1_ID)
    unless (dns_server = DnsServer[dns_server_id])
      fail "No existing Dns Server"
    end

    unless Project[Config.dns_service_project_id]
      fail "No existing Project"
    end

    unless Location[location_id]
      fail "No existing Location"
    end

    # The .assemble function is meant to be run by an operator manually. If/when we want to make this more programmatic
    # we should move this check to a pre-validation label of the prog.
    fail "Existing DNS Server VMs are not in sync, try again later" unless vms_in_sync?(dns_server.vms)

    name ||= "#{dns_server.ubid}-#{SecureRandom.alphanumeric(8).downcase}"

    DB.transaction do
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        Config.dns_service_project_id,
        sshable_unix_user: "ubi",
        location_id:,
        name: name,
        size: vm_size,
        storage_volumes: [
          {encrypted: true, size_gib: storage_size_gib}
        ],
        boot_image: "ubuntu-jammy",
        enable_ip4: true
      )

      Strand.create(prog: "DnsZone::SetupDnsServerVm", label: "start", stack: [{subject_id: vm_st.id, dns_server_id: dns_server_id}])
    end
  end

  def self.vms_in_sync?(vms)
    return true if vms.nil? || vms.empty?

    outputs = vms.map do |vm|
      lines = vm.sshable.cmd("sudo -u knot knotc", stdin: "zone-read --").split("\n")

      lines.map do |line|
        parts = line.split
        # Serial number for the SOA record can vary, and it's normal so exclude that
        if parts[3] == "SOA"
          parts.delete_at(6)
          parts.join(" ")
        else
          line
        end
      end
    end

    outputs.map(&:to_set).uniq.count == 1
  end

  def ds
    @ds ||= DnsServer[frame["dns_server_id"]]
  end

  label def start
    nap 5 unless vm.strand.label == "wait"
    register_deadline(nil, 15 * 60)
    if vm.location.aws?
      # Open UDP & TCP port 53 for DNS queries on AWS
      fw = Firewall[name: "dns", project_id: Config.dns_service_project_id]
      unless fw
        fw = Firewall.create(name: "dns", location: vm.location, project_id: Config.dns_service_project_id)
        fw.add_firewall_rule(cidr: "0.0.0.0/0", port_range: 53..53, protocol: "udp")
        fw.add_firewall_rule(cidr: "::/0", port_range: 53..53, protocol: "udp")
        fw.add_firewall_rule(cidr: "0.0.0.0/0", port_range: 53..53, protocol: "tcp")
        fw.add_firewall_rule(cidr: "::/0", port_range: 53..53, protocol: "tcp")
      end
      vm.add_vm_firewall(fw)
      vm.incr_update_firewall_rules
    end
    hop_prepare
  end

  label def prepare
    sshable.cmd(<<~SH, inhost_name: vm.inhost_name)
sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo sed -i ':a;N;$!ba;s/127.0.0.1 localhost\\n\\n#/127.0.0.1 localhost\\n127.0.0.1 ':inhost_name'\\n\\n#/' /etc/hosts
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo apt-get update
sudo apt-get -y install apt-transport-https ca-certificates wget
sudo wget -O /usr/share/keyrings/cznic-labs-pkg.gpg https://pkg.labs.nic.cz/gpg
echo "deb [signed-by=/usr/share/keyrings/cznic-labs-pkg.gpg] https://pkg.labs.nic.cz/knot-dns jammy main" | sudo tee /etc/apt/sources.list.d/cznic-labs-knot-dns.list
sudo apt-get update
sudo systemctl reboot
    SH

    hop_setup_knot
  end

  label def setup_knot
    nap 5 unless sshable.available?

    sshable.cmd <<~SH
sudo apt-get -y install knot
echo "KNOTD_ARGS="-C /var/lib/knot/confdb"" | sudo tee -a /etc/default/knot
    SH

    knot_config = <<-CONF
server:
    rundir: "/run/knot"
    user: "knot:knot"
    listen: [ "0.0.0.0@53", "::@53" ]

log:
  - target: "syslog"
    any: "info"

database:
    storage: "/var/lib/knot"

acl:
  - id: "allow_dynamic_updates"
    address: "127.0.0.1/32"
    action: "update"

template:
  - id: "default"
    storage: "/var/lib/knot"
    file: "%s.zone"
    acl: "allow_dynamic_updates"
    zonefile-sync: "60"
    zonefile-load: "difference"
    journal-content: "all"


zone:
  #{ds.dns_zones.map { |dz| "- domain: \"#{dz.name}.\"" }.join("\n  ")}
    CONF

    sshable.cmd("sudo tee /etc/knot/knot.conf > /dev/null", stdin: knot_config)

    hop_sync_zones
  end

  label def sync_zones
    nap 5 if ds.dns_zones.any?(&:refresh_dns_servers_set?)

    ds.dns_zones.each do |dz|
      zone_config = <<-CONF
#{dz.name}.          3600    SOA     ns.#{dz.name}. #{dz.name}. 37 86400 7200 1209600 #{dz.neg_ttl}
#{dz.name}.          3600    NS      #{ds.name}.
      CONF
      sshable.cmd("sudo -u knot tee /var/lib/knot/:name.zone > /dev/null", name: dz.name, stdin: zone_config)
    end

    sshable.cmd "sudo systemctl restart knot"

    ds.dns_zones.each(&:purge_obsolete_records)

    commands = ds.dns_zones.flat_map do |dz|
      ["zone-abort #{dz.name}", "zone-begin #{dz.name}"] +
        dz.records.map do |r|
          "zone-set #{dz.name} #{r.name} #{r.ttl} #{r.type} #{r.data}"
        end + ["zone-commit #{dz.name}", "zone-flush #{dz.name}"]
    end

    # Put records
    sshable.cmd("sudo -u knot knotc", stdin: commands.join("\n"))

    hop_validate
  end

  label def validate
    hop_sync_zones unless Prog::DnsZone::SetupDnsServerVm.vms_in_sync?(ds.vms + [vm])
    ds.add_vm vm unless ds.vms.map(&:id).include? vm.id
    pop "created VM for DnsServer"
  end
end
