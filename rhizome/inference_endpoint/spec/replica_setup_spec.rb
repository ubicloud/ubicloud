# frozen_string_literal: true

require_relative "../lib/replica_setup"
require "tmpdir"

RSpec.describe ReplicaSetup do
  subject(:rs) { described_class.new }

  describe "#inference_gateway_service" do
    it "returns the correct path" do
      expect(rs.inference_gateway_service).to eq("/etc/systemd/system/inference-gateway.service")
    end
  end

  describe "#inference_engine_service" do
    it "returns the correct path" do
      expect(rs.inference_engine_service).to eq("/etc/systemd/system/inference-engine.service")
    end
  end

  describe "#lb_cert_download_service" do
    it "returns the correct path" do
      expect(rs.lb_cert_download_service).to eq("/etc/systemd/system/lb-cert-download.service")
    end
  end

  describe "#lb_cert_download_timer" do
    it "returns the correct path" do
      expect(rs.lb_cert_download_timer).to eq("/etc/systemd/system/lb-cert-download.timer")
    end
  end

  describe "#common_systemd_settings" do
    it "includes key security settings" do
      settings = rs.common_systemd_settings
      expect(settings).to include("NoNewPrivileges=yes")
      expect(settings).to include("ProtectKernelTunables=yes")
      expect(settings).to include("PrivateNetwork=no")
    end
  end

  describe "#write" do
    it "writes content to a file" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "file")
        rs.write(file, "content")
        expect(File.read(file)).to eq "content\n"
      end
    end
  end

  describe "#write_inference_gateway_service" do
    it "writes to the inference gateway service path" do
      expect(rs).to receive(:write).with("/etc/systemd/system/inference-gateway.service", "content")
      rs.write_inference_gateway_service("content")
    end
  end

  describe "#write_inference_engine_service" do
    it "writes to the inference engine service path" do
      expect(rs).to receive(:write).with("/etc/systemd/system/inference-engine.service", "content")
      rs.write_inference_engine_service("content")
    end
  end

  describe "#write_lb_cert_download_service" do
    it "writes to the cert download service path" do
      expect(rs).to receive(:write).with("/etc/systemd/system/lb-cert-download.service", "content")
      rs.write_lb_cert_download_service("content")
    end
  end

  describe "#write_lb_cert_download_timer" do
    it "writes to the cert download timer path" do
      expect(rs).to receive(:write).with("/etc/systemd/system/lb-cert-download.timer", "content")
      rs.write_lb_cert_download_timer("content")
    end
  end

  describe "#write_config_files" do
    it "writes the inference gateway config file" do
      expect(rs).to receive(:safe_write_to_file).with(
        "/ie/workdir/inference-gateway.conf",
        satisfy { |content|
          content.include?("IG_LISTEN_ADDRESS=\"0.0.0.0:8080\"") &&
            content.include?("IG_REPLICA_UBID=replica-123") &&
            content.include?("IG_MAX_REQUESTS=100") &&
            content.include?("IG_SSL_CRT_PATH=/certs/server.crt") &&
            content.include?("IG_SSL_KEY_PATH=/certs/server.key")
        },
      )
      rs.write_config_files("replica-123", "/certs/server.crt", "/certs/server.key", 8080, 100)
    end
  end

  describe "#install_systemd_units" do
    it "writes all systemd unit files and reloads daemon" do
      expect(rs).to receive(:write_lb_cert_download_service).with(satisfy { |s|
        s.include?("download-lb-cert") && s.include?("NoNewPrivileges=yes")
      })
      expect(rs).to receive(:write_lb_cert_download_timer).with(satisfy { |s|
        s.include?("OnActiveSec=1h") && s.include?("timers.target")
      })
      expect(rs).to receive(:write_inference_gateway_service).with(satisfy { |s|
        s.include?("inference-gateway") && s.include?("KillSignal=SIGINT")
      })
      expect(rs).to receive(:write_inference_engine_service).with(satisfy { |s|
        s.include?("/usr/bin/start-engine") && s.include?("multi-user.target")
      })
      expect(rs).to receive(:_run_command).with("systemctl daemon-reload")

      rs.install_systemd_units("/usr/bin/start-engine")
    end
  end

  describe "#start_systemd_units" do
    it "enables and starts the required systemd units" do
      expect(rs).to receive(:_run_command).with("systemctl enable --now lb-cert-download.timer")
      expect(rs).to receive(:_run_command).with("systemctl enable --now inference-engine.service")
      rs.start_systemd_units
    end
  end

  describe "#prep" do
    it "calls write_config_files, install_systemd_units, and start_systemd_units in order" do
      expect(rs).to receive(:write_config_files).with("rep-ubid", "/c.crt", "/k.key", 9000, 50).ordered
      expect(rs).to receive(:install_systemd_units).with("/bin/engine").ordered
      expect(rs).to receive(:start_systemd_units).ordered

      rs.prep(
        engine_start_cmd: "/bin/engine",
        replica_ubid: "rep-ubid",
        ssl_crt_path: "/c.crt",
        ssl_key_path: "/k.key",
        gateway_port: 9000,
        max_requests: 50,
      )
    end
  end
end
