# frozen_string_literal: true

class Prog::SetupStorageTrim < Prog::Base
  subject_is :sshable

  label def start
    sshable.cmd("sudo mkdir -p /etc/systemd/system/fstrim.timer.d /etc/systemd/system/fstrim.service.d")
    sshable.write_file("/etc/systemd/system/fstrim.timer.d/schedule.conf", <<CONF)
[Timer]
OnCalendar=
OnCalendar=*-*-* 00/3:00:00
AccuracySec=1min
RandomizedDelaySec=10min
CONF
    sshable.write_file("/etc/systemd/system/fstrim.service.d/minimum.conf", <<CONF)
[Service]
ExecStart=
ExecStart=/sbin/fstrim --all --verbose --quiet-unsupported --minimum 2M
CONF
    sshable.cmd("sudo systemctl daemon-reload")
    sshable.cmd("sudo systemctl enable fstrim.timer")
    sshable.cmd("sudo systemctl restart fstrim.timer")
    pop "fstrim timer configured"
  end
end
