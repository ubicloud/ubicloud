# frozen_string_literal: true

require_relative "../lib/pg_bouncer_setup"

RSpec.describe PgBouncerSetup do
  let(:version) { "17-main" }
  let(:max_connections) { 100 }
  let(:num_instances) { 2 }
  let(:user_config) { {} }
  let(:pgbouncer_setup) { described_class.new(version, max_connections, num_instances, user_config) }

  describe "#pgbouncer_ini_content" do
    let(:config) { pgbouncer_setup.pgbouncer_ini_content(1) }

    it "sets correct max_client_conn based on num_instances" do
      expect(config).to include("max_client_conn = 2500")
    end

    it "sets correct max_db_connections based on max_connections and num_instances" do
      expect(config).to include("max_db_connections = 50")
    end

    it "configures TLS to require tlsv1.3" do
      expect(config).to include("client_tls_sslmode = require")
      expect(config).to include("client_tls_protocols = tlsv1.3")
    end

    it "uses correct auth_hba_file path based on version" do
      expect(config).to include("auth_hba_file = /etc/postgresql/17-main/main/pg_hba.conf")
    end

    it "sets auth_dbname to ubi_admin" do
      expect(config).to include("auth_dbname = ubi_admin")
    end

    it "sets the pool_mode to transaction" do
      expect(config).to include("pool_mode = transaction")
    end

    it "sets peer_id based on instance_id" do
      config_1 = pgbouncer_setup.pgbouncer_ini_content(1)
      config_2 = pgbouncer_setup.pgbouncer_ini_content(2)

      expect(config_1).to include("peer_id = 1")
      expect(config_2).to include("peer_id = 2")
    end

    it "includes user_config settings" do
      setup_with_user_config = described_class.new(version, max_connections, num_instances, {"default_pool_size" => "20", "reserve_pool_size" => "5"})
      config = setup_with_user_config.pgbouncer_ini_content(1)

      expect(config).to include("default_pool_size = 20")
      expect(config).to include("reserve_pool_size = 5")
    end

    it "configures auth_type as hba" do
      expect(config).to include("auth_type = hba")
    end

    it "sets listen_port to 6432" do
      expect(config).to include("listen_port = 6432")
    end
  end

  describe "#service_template_content" do
    let(:content) { pgbouncer_setup.service_template_content }

    it "sets service type to notify" do
      expect(content).to include("Type=notify")
    end

    it "runs as postgres user" do
      expect(content).to include("User=postgres")
    end

    it "references pgbouncer executable" do
      expect(content).to include("ExecStart=/usr/sbin/pgbouncer")
    end
  end

  describe "#socket_template_content" do
    let(:content) { pgbouncer_setup.socket_template_content }

    it "listens on port 6432" do
      expect(content).to include("ListenStream=6432")
    end

    it "enables ReusePort" do
      expect(content).to include("ReusePort=true")
    end
  end

  describe "#port_num" do
    it "returns port number offset from 50000" do
      expect(pgbouncer_setup.port_num(1)).to eq(50001)
      expect(pgbouncer_setup.port_num(5)).to eq(50005)
    end
  end

  describe "#peer_config" do
    it "generates peer configuration for all instances" do
      config = pgbouncer_setup.peer_config

      expect(config).to include("[peers]")
      expect(config).to include("1 = host=/tmp/.s.PGSQL.50001")
      expect(config).to include("2 = host=/tmp/.s.PGSQL.50002")
    end
  end

  describe "#pgbouncer_service_file_path" do
    it "returns the correct service template path" do
      expect(pgbouncer_setup.pgbouncer_service_file_path).to eq("/etc/systemd/system/pgbouncer@.service")
    end
  end

  describe "#socket_service_file_path" do
    it "returns the correct socket template path" do
      expect(pgbouncer_setup.socket_service_file_path).to eq("/etc/systemd/system/pgbouncer@.socket")
    end
  end

  describe "#create_service_templates" do
    it "writes service and socket templates and reloads systemd" do
      expect(File).to receive(:write).with("/etc/systemd/system/pgbouncer@.service", pgbouncer_setup.service_template_content)
      expect(File).to receive(:write).with("/etc/systemd/system/pgbouncer@.socket", pgbouncer_setup.socket_template_content)
      expect(pgbouncer_setup).to receive(:r).with("systemctl daemon-reload")
      pgbouncer_setup.create_service_templates
    end
  end

  describe "#create_pgbouncer_config" do
    it "writes config files for each instance" do
      expect(File).to receive(:write).with("/etc/pgbouncer/pgbouncer_50001.ini", pgbouncer_setup.pgbouncer_ini_content(1))
      expect(File).to receive(:write).with("/etc/pgbouncer/pgbouncer_50002.ini", pgbouncer_setup.pgbouncer_ini_content(2))
      pgbouncer_setup.create_pgbouncer_config
    end
  end

  describe "#disable_default_pgbouncer" do
    it "disables and stops the default pgbouncer service" do
      expect(pgbouncer_setup).to receive(:r).with("systemctl disable --now pgbouncer")
      pgbouncer_setup.disable_default_pgbouncer
    end
  end

  describe "#enable_and_start_service" do
    it "reloads or enables and starts each pgbouncer instance" do
      expect(pgbouncer_setup).to receive(:r).with("systemctl reload pgbouncer@50001 || systemctl enable --now pgbouncer@50001")
      expect(pgbouncer_setup).to receive(:r).with("systemctl reload pgbouncer@50002 || systemctl enable --now pgbouncer@50002")
      pgbouncer_setup.enable_and_start_service
    end
  end

  describe "#setup" do
    it "creates service templates, config, disables default, and enables instances" do
      expect(pgbouncer_setup).to receive(:create_service_templates).ordered
      expect(pgbouncer_setup).to receive(:create_pgbouncer_config).ordered
      expect(pgbouncer_setup).to receive(:disable_default_pgbouncer).ordered
      expect(pgbouncer_setup).to receive(:enable_and_start_service).ordered
      pgbouncer_setup.setup
    end
  end
end
