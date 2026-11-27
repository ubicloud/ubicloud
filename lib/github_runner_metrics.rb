# frozen_string_literal: true

require "base64"

# sysstat in a runner VM writes a sample every 5 seconds into a ring of
# fixed-size JSON lines: its unencrypted metrics disk on metal, or a tmpfs
# file elsewhere.
module GithubRunnerMetrics
  GUEST_WRITER = <<~'WRITER'
    #!/bin/bash
    set -euo pipefail
    # sadf prints decimals in the locale's format.
    export LC_ALL=C
    ring=$1
    slot_size=4096
    if [ -b "$ring" ]; then
      size=$(blockdev --getsize64 "$ring")
      # Past the guest page cache, so the host reads each write.
      direct=(oflag=direct)
    else
      size=$(stat -c %s "$ring")
      direct=()
    fi
    slots=$((size / slot_size))
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
      # Two records 5 seconds apart, for rates.
      rm -f "$work/sa"
      /usr/lib/sysstat/sadc -S XDISK 5 2 "$work/sa"
      # The flat JSON line RunnerMetricsEntry accepts, or nothing if a metric is missing.
      line=$(sadf -j "$work/sa" -- -u -r -q -d -n DEV -F MOUNT --dev="$disk" --iface="$iface" --fs=/ | jq -c --argjson seq "$seq" '
        .sysstat.hosts[0].statistics[0] as $s |
        {
          seq: $seq,
          time: ($s.timestamp | "\(.date)T\(.time)Z" | fromdateiso8601),
          runner_cpu_load_user: $s["cpu-load"][0].user,
          runner_cpu_load_nice: $s["cpu-load"][0].nice,
          runner_cpu_load_system: $s["cpu-load"][0].system,
          runner_cpu_load_iowait: $s["cpu-load"][0].iowait,
          runner_cpu_load_steal: $s["cpu-load"][0].steal,
          runner_queue_ldavg_1: $s.queue["ldavg-1"],
          runner_queue_ldavg_5: $s.queue["ldavg-5"],
          runner_queue_ldavg_15: $s.queue["ldavg-15"],
          runner_memory_memused: $s.memory.memused,
          runner_memory_avail: $s.memory.avail,
          runner_memory_cached: $s.memory.cached,
          runner_filesystems_fsused_percent: $s.filesystems[0]["%fsused"],
          runner_disk_rkb: $s.disk[0].rkB,
          runner_disk_wkb: $s.disk[0].wkB,
          runner_net_dev_rxkb: $s.network["net-dev"][0].rxkB,
          runner_net_dev_txkb: $s.network["net-dev"][0].txkB
        } | select(all(.[]; type == "number"))')
      if [ -z "$line" ]; then
        echo "skipping a sample with a missing metric" >&2
        continue
      fi
      # Pad to one slot and write it at seq % slots.
      printf '%-*s\n' $((slot_size - 1)) "$line" |
        dd of="$ring" bs="$slot_size" seek=$((seq % slots)) count=1 iflag=fullblock "${direct[@]}" conv=notrunc status=none
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

  RING_FILE_SIZE = 1024 * 1024

  # Without a host to read a disk, the ring is a file monitor reads over SSH.
  FILE_UNIT = <<~UNIT
    [Unit]
    Description=Ubicloud runner metrics writer

    [Service]
    RuntimeDirectory=ubicloud-metrics
    RuntimeDirectoryPreserve=yes
    ExecStartPre=/usr/bin/truncate -s #{RING_FILE_SIZE} /run/ubicloud-metrics/ring
    ExecStart=/usr/local/bin/ubicloud-metrics-writer /run/ubicloud-metrics/ring
    Restart=always
    RestartSec=5
  UNIT

  # Base64 survives the comment stripping in setup_environment.
  def self.install_command(metal:)
    unit = metal ? DISK_UNIT : FILE_UNIT
    NetSsh.command(<<~COMMAND, writer: Base64.strict_encode64(GUEST_WRITER), unit: Base64.strict_encode64(unit))
      echo :writer | base64 -d | sudo tee /usr/local/bin/ubicloud-metrics-writer > /dev/null
      sudo chmod 755 /usr/local/bin/ubicloud-metrics-writer
      echo :unit | base64 -d | sudo tee /etc/systemd/system/ubicloud-metrics-writer.service > /dev/null
      sudo systemctl daemon-reload
      sudo systemctl start ubicloud-metrics-writer.service
    COMMAND
  end

  class InvalidOutput < StandardError; end

  # Returns the Prometheus samples and the "<vm> <file>" lines to ack from
  # runner-metrics-collect output. The host agents write only validated
  # entries, {"time":<seconds>,"<metric>":<value>,...}, so anything else raises.
  def self.parse(output, labels_by_vm_name)
    label_texts = labels_by_vm_name.transform_values do |labels|
      labels.map { |key, value| "#{key}=\"#{value}\"" }.join(",")
    end
    samples = +""
    acks = []
    output.each_line(chomp: true) do |line|
      vm_name, file, json = line.split(" ", 3)
      label_text = label_texts[vm_name]
      entry = JSON.parse(json) if label_text && json
      time = entry.delete("time") if entry.is_a?(Hash)
      fail InvalidOutput, "unexpected line: #{line}" unless time.is_a?(Integer)

      ack = "#{vm_name} #{file}"
      acks << ack unless acks.last == ack
      entry.each { |metric, value| samples << "#{metric}{#{label_text}} #{value} #{time * 1000}\n" }
    end

    [samples, acks]
  end
end
