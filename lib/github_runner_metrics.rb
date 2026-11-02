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
end
