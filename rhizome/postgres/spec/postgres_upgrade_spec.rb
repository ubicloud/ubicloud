# frozen_string_literal: true

require_relative "../lib/postgres_upgrade"

RSpec.describe PostgresUpgrade do
  let(:logger) { instance_double(Logger, info: nil, warn: nil) }
  let(:postgres_upgrade) { described_class.new("17", logger) }

  before do
    # Mock the util methods from common/lib/util
    allow(postgres_upgrade).to receive(:r)
    stub_const("EXTENSION_UPGRADE_SCRIPTS", {
      17 => {
        "postgis" => "SELECT postgis_extensions_upgrade();"
      }
    })
  end

  describe "#initialize" do
    it "sets version and prev_version correctly" do
      upgrade = described_class.new("17", logger)
      expect(upgrade.instance_variable_get(:@version)).to eq(17)
      expect(upgrade.instance_variable_get(:@prev_version)).to eq(16)
    end

    it "converts string version to integer" do
      upgrade = described_class.new("16", logger)
      expect(upgrade.instance_variable_get(:@version)).to eq(16)
      expect(upgrade.instance_variable_get(:@prev_version)).to eq(15)
    end
  end

  describe "#create_upgrade_dir" do
    it "creates upgrade directory with correct permissions" do
      expect(postgres_upgrade).to receive(:r).with("sudo mkdir -p /dat/upgrade/17")
      expect(postgres_upgrade).to receive(:r).with("sudo chown postgres:postgres /dat/upgrade/17")
      postgres_upgrade.create_upgrade_dir
    end
  end

  describe "#disable_archive_mode" do
    it "disables archive mode and reloads configuration" do
      expect(postgres_upgrade).to receive(:r).with("echo 'archive_command = true' | sudo tee /etc/postgresql/16/main/conf.d/100-upgrade.conf")
      expect(postgres_upgrade).to receive(:r).with("sudo pg_ctlcluster 16 main reload")
      postgres_upgrade.disable_archive_mode
    end
  end

  describe "#promote" do
    it "promotes server if in recovery mode" do
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null || echo 't'").and_return("t\n")
      expect(postgres_upgrade).to receive(:r).with("sudo pg_ctlcluster promote 16 main", expect: [0, 1])
      postgres_upgrade.promote(16)
    end

    it "skips promotion if server is already promoted" do
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null || echo 't'").and_return("f\n")
      expect(postgres_upgrade).not_to receive(:r).with("sudo pg_ctlcluster promote 16 main", expect: [0, 1])
      expect(logger).to receive(:info).with("Server is already promoted (not in recovery mode)")
      postgres_upgrade.promote(16)
    end
  end

  describe "#disable_previous_version" do
    it "disables and stops previous version service" do
      expect(postgres_upgrade).to receive(:r).with("sudo systemctl disable --now postgresql@16-main")
      postgres_upgrade.disable_previous_version
    end
  end

  describe "#initialize_new_version" do
    it "sets up new postgres version" do
      pg_setup = instance_double(PostgresSetup)
      expect(PostgresSetup).to receive(:new).with(17).and_return(pg_setup)
      expect(pg_setup).to receive(:install_packages)
      expect(pg_setup).to receive(:setup_data_directory)
      expect(pg_setup).to receive(:create_cluster)
      postgres_upgrade.initialize_new_version
    end
  end

  describe "#stop_new_version" do
    it "stops new version service" do
      expect(postgres_upgrade).to receive(:r).with("sudo systemctl stop postgresql@17-main")
      postgres_upgrade.stop_new_version
    end
  end

  describe "#run_check" do
    it "runs pg_upgrade with --check option" do
      expect(postgres_upgrade).to receive(:run_pg_upgrade_cmd).with("--check")
      postgres_upgrade.run_check
    end
  end

  describe "#run_pg_upgrade" do
    it "runs pg_upgrade with --link option" do
      expect(postgres_upgrade).to receive(:run_pg_upgrade_cmd).with("--link")
      postgres_upgrade.run_pg_upgrade
    end
  end

  describe "#enable_new_version" do
    it "enables and starts new version service" do
      expect(postgres_upgrade).to receive(:r).with("sudo systemctl enable --now postgresql@17-main")
      postgres_upgrade.enable_new_version
    end
  end

  describe "#wait_for_postgres_to_start" do
    it "waits for postgres to become ready" do
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres pg_isready").and_raise(StandardError).once
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres pg_isready").and_return("")
      expect(postgres_upgrade).to receive(:sleep).with(1)

      postgres_upgrade.wait_for_postgres_to_start
    end
  end

  describe "#run_post_upgrade_scripts" do
    it "executes all SQL scripts in upgrade directory" do
      expect(Dir).to receive(:glob).with("/dat/upgrade/17/*.sql").and_yield("/dat/upgrade/17/script1.sql").and_yield("/dat/upgrade/17/script2.sql")
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -v 'ON_ERROR_STOP=1' -f /dat/upgrade/17/script1.sql")
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -v 'ON_ERROR_STOP=1' -f /dat/upgrade/17/script2.sql")
      postgres_upgrade.run_post_upgrade_scripts
    end
  end

  describe "#run_post_upgrade_extension_update" do
    it "updates extensions on databases where they are installed" do
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -t -c 'SELECT datname FROM pg_database WHERE datistemplate = false;'").and_return("postgres\nmydb\n")
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -d postgres -v 'ON_ERROR_STOP=1' -t", stdin: "SELECT 1 FROM pg_extension WHERE extname = 'postgis'").and_return("1")
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -d mydb -v 'ON_ERROR_STOP=1' -t", stdin: "SELECT 1 FROM pg_extension WHERE extname = 'postgis'").and_return("")
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -d postgres -v 'ON_ERROR_STOP=1'", stdin: "SELECT postgis_extensions_upgrade();")
      expect(logger).to receive(:info).with("Running post upgrade extension update for postgis")
      expect(logger).to receive(:info).with("Running post upgrade extension update for postgis on database postgres")

      postgres_upgrade.run_post_upgrade_extension_update
    end

    it "skips databases where extension is not installed" do
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -t -c 'SELECT datname FROM pg_database WHERE datistemplate = false;'").and_return("postgres\n")
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -d postgres -v 'ON_ERROR_STOP=1' -t", stdin: "SELECT 1 FROM pg_extension WHERE extname = 'postgis'").and_return("")
      expect(postgres_upgrade).not_to receive(:r).with("sudo -u postgres psql -d postgres -v 'ON_ERROR_STOP=1'", stdin: anything)
      expect(logger).to receive(:info).with("Running post upgrade extension update for postgis")

      postgres_upgrade.run_post_upgrade_extension_update
    end

    it "escapes dangerous database and extension names correctly" do
      stub_const("EXTENSION_UPGRADE_SCRIPTS", {
        17 => {
          "ext'sname" => "ALTER EXTENSION \"ext'sname\" UPDATE;"
        }
      })
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -t -c 'SELECT datname FROM pg_database WHERE datistemplate = false;'").and_return("mydb$(pwd)\n")
      expect(logger).to receive(:info).with("Running post upgrade extension update for ext'sname")
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -d mydb\\$\\(pwd\\) -v 'ON_ERROR_STOP=1' -t", stdin: "SELECT 1 FROM pg_extension WHERE extname = 'ext''sname'").and_return("1")
      expect(postgres_upgrade).to receive(:r).with("sudo -u postgres psql -d mydb\\$\\(pwd\\) -v 'ON_ERROR_STOP=1'", stdin: "ALTER EXTENSION \"ext'sname\" UPDATE;")
      expect(logger).to receive(:info).with("Running post upgrade extension update for ext'sname on database mydb$(pwd)")

      postgres_upgrade.run_post_upgrade_extension_update
    end
  end

  describe "#run_pg_upgrade_cmd" do
    it "changes directory and runs pg_upgrade command" do
      expect(Dir).to receive(:chdir).with("/dat/upgrade/17").and_yield
      expect(postgres_upgrade).to receive(:pg_upgrade_cmdline).with("--check").and_return("pg_upgrade_command")
      expect(postgres_upgrade).to receive(:r).with("pg_upgrade_command")

      postgres_upgrade.run_pg_upgrade_cmd("--check")
    end
  end

  describe "#pg_upgrade_cmdline" do
    it "constructs correct pg_upgrade command" do
      expected_cmd = "sudo -u postgres /usr/lib/postgresql/17/bin/pg_upgrade --old-bindir /usr/lib/postgresql/16/bin --old-datadir /etc/postgresql/16/main/ --new-bindir /usr/lib/postgresql/17/bin --new-datadir /etc/postgresql/17/main/ --check"
      expect(postgres_upgrade.pg_upgrade_cmdline("--check")).to eq(expected_cmd)
    end
  end

  describe "#upgrade" do
    it "executes complete upgrade workflow in correct order" do
      expect(postgres_upgrade).to receive(:create_upgrade_dir).ordered
      expect(postgres_upgrade).to receive(:disable_archive_mode).ordered
      expect(postgres_upgrade).to receive(:wait_for_postgres_to_start).ordered
      expect(postgres_upgrade).to receive(:promote).with(16).ordered
      expect(postgres_upgrade).to receive(:initialize_new_version).ordered
      expect(postgres_upgrade).to receive(:stop_new_version).ordered
      expect(postgres_upgrade).to receive(:run_check).ordered
      expect(postgres_upgrade).to receive(:run_pg_upgrade).ordered
      expect(postgres_upgrade).to receive(:enable_new_version).ordered
      expect(postgres_upgrade).to receive(:wait_for_postgres_to_start).ordered
      expect(postgres_upgrade).to receive(:run_post_upgrade_scripts).ordered
      expect(postgres_upgrade).to receive(:run_post_upgrade_extension_update).ordered

      # Mock puts calls
      allow(postgres_upgrade).to receive(:puts)

      postgres_upgrade.upgrade
    end
  end
end
