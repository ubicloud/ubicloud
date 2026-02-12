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
end
