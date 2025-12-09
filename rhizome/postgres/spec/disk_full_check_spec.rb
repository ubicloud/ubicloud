# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe "disk-full-check" do
  let(:script) { File.expand_path("../bin/disk-full-check", __dir__) }
  let(:tmpdir) { Dir.mktmpdir }
  let(:dat) { File.join(tmpdir, "dat") }
  let(:bin) { File.join(tmpdir, "bin") }
  let(:auto_conf) { File.join(dat, "16", "data", "postgresql.auto.conf") }
  let(:pending_restart) { File.join(dat, "disk-full-read-only-pending-restart-16") }
  let(:human_buffer) { File.join(dat, "disk-full-human-buffer") }

  before do
    FileUtils.mkdir_p(File.join(dat, "16", "data"))
    FileUtils.mkdir_p(bin)
    FileUtils.touch(File.join(dat, "pg_ctl_calls"))

    File.write(File.join(bin, "pg_ctl"), <<~SH)
      #!/bin/sh
      echo "$1" >> "#{dat}/pg_ctl_calls"
    SH
    File.chmod(0o755, File.join(bin, "pg_ctl"))

    File.write(File.join(bin, "fallocate"), <<~SH)
      #!/bin/sh
      touch "$3"
    SH
    File.chmod(0o755, File.join(bin, "fallocate"))

    File.write(auto_conf, "\n")
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def fake_df(usedp, avail)
    File.write(File.join(bin, "df"), <<~SH)
      #!/bin/sh
      echo "Filesystem     1B-blocks          Used     Available Use% Mounted on"
      echo "/dev/sda1      107374182400 53687091200 #{avail} #{usedp}% #{dat}"
    SH
    File.chmod(0o755, File.join(bin, "df"))
  end

  def run_check
    stdout, stderr, status = Open3.capture3({"PATH" => "#{bin}:#{ENV["PATH"]}", "DAT" => dat}, "bash", script, "16")
    raise "disk-full-check failed: #{stderr}" unless status.success?
    stdout
  end

  def pg_ctl_calls
    File.read(File.join(dat, "pg_ctl_calls")).strip
  end

  def auto_conf_content
    File.read(auto_conf)
  end

  describe "recovery, >7GB available" do
    before { fake_df(50, 53_687_091_200) }

    it "creates human buffer" do
      run_check
      expect(File.exist?(human_buffer)).to be true
    end

    it "does not recreate existing buffer" do
      FileUtils.touch(human_buffer)
      run_check
      expect(pg_ctl_calls).to eq ""
    end

    it "clears read-only and removes pending restart marker" do
      File.write(auto_conf, "default_transaction_read_only = 'on'\n")
      FileUtils.touch(pending_restart)
      run_check
      expect(auto_conf_content).not_to include("default_transaction_read_only")
      expect(File.exist?(pending_restart)).to be false
      expect(pg_ctl_calls).to eq "reload"
    end
  end

  describe "margin, 5-7GB available" do
    before { fake_df(50, 6_000_000_000) }

    it "takes no action" do
      run_check
      expect(pg_ctl_calls).to eq ""
      expect(File.exist?(human_buffer)).to be false
    end
  end

  describe "readonly, <5GB available" do
    before { fake_df(50, 4_000_000_000) }

    it "sets read-only and reloads" do
      run_check
      expect(auto_conf_content).to include("default_transaction_read_only = 'on'")
      expect(File.exist?(pending_restart)).to be true
      expect(pg_ctl_calls).to eq "reload"
    end

    it "does not reload while read-only" do
      File.write(auto_conf, "default_transaction_read_only = 'on'\n")
      run_check
      expect(pg_ctl_calls).to eq ""
      expect(File.exist?(pending_restart)).to be false
    end

    it "appends newline before read-only when file lacks trailing newline" do
      File.write(auto_conf, "some_setting = 'value'")
      run_check
      expect(auto_conf_content).to eq "some_setting = 'value'\ndefault_transaction_read_only = 'on'\n"
    end
  end

  describe "critical, <3GB available" do
    before { fake_df(50, 2_000_000_000) }

    it "restarts when pending restart marker exists" do
      File.write(auto_conf, "default_transaction_read_only = 'on'\n")
      FileUtils.touch(pending_restart)
      run_check
      expect(pg_ctl_calls).to eq "restart"
      expect(File.exist?(pending_restart)).to be false
    end

    it "does not restart without pending restart marker" do
      File.write(auto_conf, "default_transaction_read_only = 'on'\n")
      run_check
      expect(pg_ctl_calls).to eq ""
    end
  end
end
