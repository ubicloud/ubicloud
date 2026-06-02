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
    FileUtils.touch(File.join(dat, "psql_calls"))

    File.write(File.join(bin, "pg_ctlcluster"), <<~SH)
      #!/bin/sh
      echo "$3" >> "#{dat}/pg_ctl_calls"
    SH
    File.chmod(0o755, File.join(bin, "pg_ctlcluster"))

    # Stub psql: capture the SQL passed via -c so we can assert the issued
    # statements. For the slot-drop+sum query (single call now), echo
    # STUCK_SLOTS_BYTES (defaulting to 0) so the bash caller can decide
    # whether to follow up with a CHECKPOINT.
    File.write(File.join(bin, "psql"), <<~SH)
      #!/bin/sh
      while [ $# -gt 0 ]; do
        if [ "$1" = "-c" ]; then
          shift
          echo "$1" >> "#{dat}/psql_calls"
          case "$1" in
            *pg_drop_replication_slot*|*pg_replication_slots*)
              echo "${STUCK_SLOTS_BYTES:-0}"
              ;;
          esac
          break
        fi
        shift
      done
    SH
    File.chmod(0o755, File.join(bin, "psql"))

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

  def fake_df(usedp, avail, total: 107374182400)
    used = total - avail
    File.write(File.join(bin, "df"), <<~SH)
      #!/bin/sh
      echo "Filesystem     1B-blocks          Used     Available Use% Mounted on"
      echo "/dev/sda1      #{total} #{used} #{avail} #{usedp}% #{dat}"
    SH
    File.chmod(0o755, File.join(bin, "df"))
  end

  def run_check(stuck_slots_bytes: nil)
    env = {"PATH" => "#{bin}:#{ENV["PATH"]}", "DAT" => dat}
    env["STUCK_SLOTS_BYTES"] = stuck_slots_bytes.to_s if stuck_slots_bytes
    stdout, stderr, status = Open3.capture3(env, "bash", script, "16")
    raise "disk-full-check failed: #{stderr}" unless status.success?
    stdout
  end

  def pg_ctl_calls
    File.read(File.join(dat, "pg_ctl_calls")).strip
  end

  def psql_calls
    File.read(File.join(dat, "psql_calls")).strip
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

    it "terminates customer backends when pending restart marker exists" do
      File.write(auto_conf, "default_transaction_read_only = 'on'\n")
      FileUtils.touch(pending_restart)
      run_check
      expect(pg_ctl_calls).to eq ""
      expect(psql_calls).to include("pg_terminate_backend")
      expect(psql_calls).to include("ubi_replication")
      expect(psql_calls).to include("ubi_monitoring")
      expect(File.exist?(pending_restart)).to be false
    end

    it "does not terminate backends without pending restart marker" do
      File.write(auto_conf, "default_transaction_read_only = 'on'\n")
      run_check
      expect(pg_ctl_calls).to eq ""
      expect(psql_calls).to eq ""
    end
  end

  describe "inactive or lagging logical slot cleanup at restart_threshold" do
    before do
      fake_df(50, 2_000_000_000) # < 3GB restart threshold
      File.write(auto_conf, "default_transaction_read_only = 'on'\n")
      FileUtils.touch(pending_restart)
    end

    it "issues a single drop+sum query over pg_replication_slots" do
      run_check
      expect(psql_calls).to include("pg_drop_replication_slot")
      expect(psql_calls).to include("pg_replication_slots")
      expect(psql_calls).to include("slot_type = 'logical'")
      expect(psql_calls).to include("NOT active")
      expect(psql_calls).to include("2147483648")
    end

    it "no matching slots (sum=0): skips CHECKPOINT, terminates backends, no freed-bytes log" do
      out = run_check
      expect(psql_calls).not_to include("CHECKPOINT")
      expect(psql_calls).to include("pg_terminate_backend")
      expect(out).not_to include("dropped inactive or lagging logical slots")
    end

    it "inactive or lagging slots (sum>0): CHECKPOINTs, logs freed bytes, exits (no terminate this tick)" do
      out = run_check(stuck_slots_bytes: 3_221_225_472) # 3 GB
      expect(psql_calls).to include("CHECKPOINT")
      # Exit-after-drop: next 20s tick re-reads df and decides whether more
      # mitigation is still needed. Terminate must NOT have run this tick.
      expect(psql_calls).not_to include("pg_terminate_backend")
      # Pending marker stays so the next tick can still enter this branch.
      expect(File.exist?(pending_restart)).to be true
      # Operator-visible log line includes the freed byte count.
      expect(out).to include("dropped inactive or lagging logical slots holding 3221225472 bytes of WAL")
    end
  end

  # Tier boundaries (matching disk-full-check):
  #   <= 64GB   (hobby)        recover 2GB,  readonly 1GB,   restart 512MB
  #   <= 128GB                 recover 7GB,  readonly 5GB,   restart 3GB
  #   <= 512GB                 recover 10GB, readonly 7GB,   restart 5GB
  #    > 512GB  (percentage)   recover 3%,   readonly 2%,    restart 1%
  describe "tier: <= 64GB (hobby)" do
    let(:total) { 32 * 1024**3 } # 32GB

    it "stays in margin between 1GB and 2GB available" do
      fake_df(95, 1_500_000_000, total: total) # 1.5GB
      run_check
      expect(pg_ctl_calls).to eq ""
      expect(File.exist?(human_buffer)).to be false
    end

    it "sets read-only below 1GB" do
      fake_df(98, 900_000_000, total: total) # 0.9GB < 1GB
      run_check
      expect(auto_conf_content).to include("default_transaction_read_only = 'on'")
      expect(pg_ctl_calls).to eq "reload"
    end

    it "creates a 500M human buffer above 2GB" do
      fake_df(80, 3_000_000_000, total: total) # 3GB > 2GB
      run_check
      expect(File.exist?(human_buffer)).to be true
    end
  end

  describe "tier: <= 512GB" do
    let(:total) { 256 * 1024**3 } # 256GB

    it "stays in margin between 7GB and 10GB available" do
      fake_df(96, 8 * 1024**3, total: total) # 8GB: above 7GB, below 10GB
      run_check
      expect(pg_ctl_calls).to eq ""
      expect(File.exist?(human_buffer)).to be false
    end

    it "sets read-only below 7GB" do
      fake_df(97, 6 * 1024**3, total: total) # 6GB < 7GB
      run_check
      expect(auto_conf_content).to include("default_transaction_read_only = 'on'")
      expect(pg_ctl_calls).to eq "reload"
    end

    it "terminates customer backends below 5GB when pending restart marker exists" do
      fake_df(98, 4 * 1024**3, total: total) # 4GB < 5GB
      File.write(auto_conf, "default_transaction_read_only = 'on'\n")
      FileUtils.touch(pending_restart)
      run_check
      expect(psql_calls).to include("pg_terminate_backend")
      expect(File.exist?(pending_restart)).to be false
    end

    it "clears read-only above 10GB" do
      fake_df(90, 12 * 1024**3, total: total) # 12GB > 10GB
      File.write(auto_conf, "default_transaction_read_only = 'on'\n")
      FileUtils.touch(pending_restart)
      run_check
      expect(auto_conf_content).not_to include("default_transaction_read_only")
      expect(pg_ctl_calls).to eq "reload"
    end
  end

  describe "tier: > 512GB (percentage-based)" do
    let(:total) { 1024 * 1024**3 } # 1TB -> recover 3% = 30.72GB, readonly 2% = 20.48GB, restart 1% = 10.24GB

    it "stays in margin between 2% and 3%" do
      fake_df(97, 25 * 1024**3, total: total) # 25GB: above 2%(~20.5G), below 3%(~30.7G)
      run_check
      expect(pg_ctl_calls).to eq ""
      expect(File.exist?(human_buffer)).to be false
    end

    it "sets read-only below 2%" do
      fake_df(98, 15 * 1024**3, total: total) # 15GB < 2% (~20.5G)
      run_check
      expect(auto_conf_content).to include("default_transaction_read_only = 'on'")
      expect(pg_ctl_calls).to eq "reload"
    end

    it "terminates customer backends below 1% when pending restart marker exists" do
      fake_df(99, 5 * 1024**3, total: total) # 5GB < 1% (~10.24G)
      File.write(auto_conf, "default_transaction_read_only = 'on'\n")
      FileUtils.touch(pending_restart)
      run_check
      expect(psql_calls).to include("pg_terminate_backend")
    end

    it "clears read-only above 3%" do
      fake_df(90, 40 * 1024**3, total: total) # 40GB > 3% (~30.7G)
      File.write(auto_conf, "default_transaction_read_only = 'on'\n")
      run_check
      expect(auto_conf_content).not_to include("default_transaction_read_only")
      expect(pg_ctl_calls).to eq "reload"
    end
  end
end
