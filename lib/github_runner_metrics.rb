# frozen_string_literal: true

require "base64"

# sysstat in a runner VM writes a sample every 5 seconds into a ring of
# fixed-size JSON lines on its unencrypted metrics disk.
module GithubRunnerMetrics
  GUEST_WRITER = <<~'WRITER'
    #!/bin/bash
    set -euo pipefail
    # Byte lengths in ${#line}.
    export LC_ALL=C
    ring=$1
    slot_size=4096
    slots=$(($(blockdev --getsize64 "$ring") / slot_size))
    work=$(mktemp -d)
    # Sample only the root disk and the default route's interface.
    root=$(findmnt -no SOURCE /)
    disk=$(lsblk -no pkname "$root")
    disk=${disk:-$(basename "$root")}
    iface=$(ip -o route show default | sed -n '1s/.* dev \([^ ]*\).*/\1/p')
    # Continue after the newest seq on the ring if this service restarted.
    seq=$(tr -d '\0' < "$ring" | sed -n 's/^{"seq":\([0-9]*\),.*/\1/p' | sort -n | tail -n 1)
    seq=${seq:-0}
    while true; do
      seq=$((seq + 1))
      # Two records 5 seconds apart, for rates, as one JSON line.
      rm -f "$work/sa"
      /usr/lib/sysstat/sadc -S XDISK 5 2 "$work/sa"
      sample=$(sadf -j "$work/sa" -- -u -r -q -d -n DEV -F MOUNT --dev="$disk" --iface="$iface" --fs=/ | tr -d '\n\t')
      # {"seq":N,"sysstat":{...}}
      line="{\"seq\":$seq,${sample#\{}"
      if ((${#line} >= slot_size)); then
        echo "skipping a sample of ${#line} bytes" >&2
        continue
      fi
      # Pad to one slot and write it at seq % slots, past the page cache.
      printf '%-*s\n' $((slot_size - 1)) "$line" |
        dd of="$ring" bs="$slot_size" seek=$((seq % slots)) count=1 iflag=fullblock oflag=direct conv=notrunc status=none
    done
  WRITER

  DISK_UNIT = <<~UNIT
    [Unit]
    Description=Ubicloud runner metrics writer
    ConditionPathExists=/dev/disk/by-id/virtio-ubicloud-metrics

    [Service]
    ExecStart=/usr/local/bin/ubicloud-metrics-writer /dev/disk/by-id/virtio-ubicloud-metrics
    Restart=always
    RestartSec=5
  UNIT

  # Base64 survives the comment stripping in setup_environment.
  def self.install_command
    NetSsh.command(<<~COMMAND, writer: Base64.strict_encode64(GUEST_WRITER), unit: Base64.strict_encode64(DISK_UNIT))
      echo :writer | base64 -d | sudo tee /usr/local/bin/ubicloud-metrics-writer > /dev/null
      sudo chmod 755 /usr/local/bin/ubicloud-metrics-writer
      echo :unit | base64 -d | sudo tee /etc/systemd/system/ubicloud-metrics-writer.service > /dev/null
      sudo systemctl daemon-reload
      sudo systemctl start ubicloud-metrics-writer.service
    COMMAND
  end

  # section => [item name key, label, {field => metric}]
  SECTIONS = {
    "cpu-load" => ["cpu", "cpu", {"user" => "runner_cpu_load_user", "nice" => "runner_cpu_load_nice", "system" => "runner_cpu_load_system", "iowait" => "runner_cpu_load_iowait", "steal" => "runner_cpu_load_steal"}],
    "queue" => [nil, nil, {"ldavg-1" => "runner_queue_ldavg_1", "ldavg-5" => "runner_queue_ldavg_5", "ldavg-15" => "runner_queue_ldavg_15"}],
    "memory" => [nil, nil, {"memused" => "runner_memory_memused", "avail" => "runner_memory_avail", "cached" => "runner_memory_cached"}],
    "filesystems" => ["mountpoint", "mountpoint", {"%fsused" => "runner_filesystems_fsused_percent"}],
    "disk" => ["disk-device", "device", {"rkB" => "runner_disk_rkb", "wkB" => "runner_disk_wkb"}],
    "net-dev" => ["iface", "iface", {"rxkB" => "runner_net_dev_rxkb", "txkB" => "runner_net_dev_txkb"}],
  }.freeze
  MAX_ITEMS = 4
  LABEL_VALUE = %r{\A[\w./-]{1,64}\z}
  MAX_AGE = 60 * 60
  MAX_CLOCK_SKEW = 60

  # Returns the Prometheus samples and the files to ack from runner-metrics-collect output.
  def self.parse(output, labels_by_vm_name, now: Time.now)
    samples = +""
    acks = []
    output.each_line(chomp: true) do |line|
      vm_name, file, json = line.split(" ", 3)
      next unless (labels = labels_by_vm_name[vm_name])

      unless json
        acks << "#{vm_name} #{file}"
        next
      end

      entry = begin
        JSON.parse(json, max_nesting: 10)
      rescue JSON::ParserError
        next
      end
      add_samples(samples, entry, labels, now)
    end

    [samples, acks]
  end

  def self.add_samples(samples, entry, labels, now)
    stats = entry.dig("sysstat", "hosts", 0, "statistics", 0) if entry.is_a?(Hash)
    return unless stats.is_a?(Hash) && (timestamp = stats["timestamp"]).is_a?(Hash)

    time = begin
      Time.strptime("#{timestamp["date"]} #{timestamp["time"]} UTC", "%Y-%m-%d %H:%M:%S %Z")
    rescue ArgumentError
      return
    end
    return unless time.between?(now - MAX_AGE, now + MAX_CLOCK_SKEW)

    timestamp_ms = (time.to_f * 1000).to_i
    SECTIONS.each do |section, (item_key, item_label, metrics)|
      data = (section == "net-dev") ? stats.dig("network", "net-dev") : stats[section]
      items = item_key ? Array(data).first(MAX_ITEMS) : [data]
      items.each do |item|
        next unless item.is_a?(Hash)

        item_labels = labels
        if item_key
          next unless LABEL_VALUE.match?(value = item[item_key].to_s)
          item_labels = labels.merge(item_label => value)
        end
        label_text = item_labels.map { |key, label_value| "#{key}=\"#{label_value}\"" }.join(",")

        metrics.each do |field, metric|
          next unless (value = item[field]).is_a?(Numeric)

          samples << "#{metric}{#{label_text}} #{value} #{timestamp_ms}\n"
        end
      end
    end
  end
end
