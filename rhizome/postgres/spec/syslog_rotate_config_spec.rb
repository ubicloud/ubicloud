# frozen_string_literal: true

require_relative "../lib/syslog_rotate_config"

RSpec.describe SyslogRotateConfig do
  let(:syslog_rotate) { described_class.new }

  describe "#logrotate_content" do
    let(:content) { syslog_rotate.logrotate_content }

    it "caps a single generation by size" do
      expect(content).to include("maxsize 500M")
    end

    it "rotates daily rather than weekly" do
      expect(content).to include("daily")
      expect(content).not_to include("weekly")
    end

    it "bounds retention by generation count" do
      expect(content).to include("rotate 45")
    end

    it "compresses aged generations" do
      expect(content).to include("compress")
      expect(content).to include("delaycompress")
    end

    it "covers syslog and auth.log" do
      expect(content).to include("/var/log/syslog\n")
      expect(content).to include("/var/log/auth.log\n")
    end

    it "keeps the stock postrotate hook so rsyslog reopens its files" do
      expect(content).to include("postrotate")
      expect(content).to include("/usr/lib/rsyslog/rsyslog-rotate")
      expect(content).to include("endscript")
    end

    it "uses sharedscripts so postrotate runs once for all paths" do
      expect(content).to include("sharedscripts")
    end

    it "tolerates paths removed by hand" do
      expect(content).to include("missingok")
    end

    it "marks the file as managed" do
      expect(content).to include("Managed by Ubicloud")
    end
  end

  describe "#timer_override_content" do
    let(:content) { syslog_rotate.timer_override_content }

    it "resets the stock OnCalendar before setting its own" do
      # Without the empty assignment systemd appends, leaving the daily
      # trigger in place alongside the hourly one.
      expect(content).to match(/OnCalendar=\nOnCalendar=hourly/)
    end

    it "is a Timer section override" do
      expect(content).to include("[Timer]")
    end
  end

  describe "#setup" do
    before do
      allow(syslog_rotate).to receive_messages(safe_write_to_file: nil, _run_command: nil)
    end

    it "writes the logrotate config at a mode logrotate accepts" do
      expect(syslog_rotate).to receive(:safe_write_to_file).with("/etc/logrotate.d/rsyslog", syslog_rotate.logrotate_content, perm: 0o644)
      syslog_rotate.setup
    end

    it "writes the timer override at a mode logrotate accepts, into a drop-in dir it creates" do
      expect(syslog_rotate).to receive(:_run_command).with("mkdir", "-p", "/etc/systemd/system/logrotate.timer.d")
      expect(syslog_rotate).to receive(:safe_write_to_file).with("/etc/systemd/system/logrotate.timer.d/10-ubicloud-hourly.conf", syslog_rotate.timer_override_content, perm: 0o644)
      syslog_rotate.setup
    end

    it "reloads systemd and restarts the timer so the override takes effect" do
      expect(syslog_rotate).to receive(:_run_command).with("systemctl", "daemon-reload")
      expect(syslog_rotate).to receive(:_run_command).with("systemctl", "restart", "logrotate.timer")
      syslog_rotate.setup
    end
  end
end
