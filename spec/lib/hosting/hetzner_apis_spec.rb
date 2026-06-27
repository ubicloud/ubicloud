# frozen_string_literal: true

RSpec.describe Hosting::HetznerApis do
  let(:hetzner_apis) do
    vmh = create_vm_host
    vmh.sshable.update(host: "1.1.1.1")
    provider = HostProvider.create do
      it.id = vmh.id
      it.server_identifier = "123"
      it.provider_name = HostProvider::HETZNER_PROVIDER_NAME
    end
    described_class.new(provider)
  end

  let(:ssh_key) { "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDQ8Z9Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0" }

  before do
    allow(Config).to receive_messages(
      hetzner_connection_string: "https://robot-ws.your-server.de",
      hetzner_user: "user1",
      hetzner_password: "pass",
      hetzner_ssh_public_key: ssh_key,
    )
  end

  describe "reimage" do
    it "can reimage a server" do
      Excon.stub({path: "/boot/123/linux", method: :post}, {status: 200, body: ""})
      Excon.stub({path: "/reset/123", method: :post, body: "type=hw"}, {status: 200, body: ""})
      expect(hetzner_apis.reimage).to be_nil
    end

    it "raises an error if the reimage fails" do
      Excon.stub({path: "/boot/123/linux", method: :post}, {status: 200, body: ""})
      Excon.stub({path: "/reset/123", method: :post, body: "type=hw"}, {status: 400, body: ""})
      expect { hetzner_apis.reimage }.to raise_error Excon::Error::BadRequest
    end

    it "raises an error if the ssh key is not set" do
      expect(Config).to receive(:hetzner_ssh_public_key).and_return(nil)
      expect { hetzner_apis.reimage }.to raise_error RuntimeError, "hetzner_ssh_public_key is not set"
    end

    it "raises an error if the boot fails" do
      Excon.stub({path: "/boot/123/linux", method: :post}, {status: 400, body: ""})
      expect { hetzner_apis.reimage }.to raise_error Excon::Error::BadRequest
    end
  end

  describe "enable_rescue" do
    it "can enable the rescue system" do
      Excon.stub({path: "/boot/123/rescue", method: :post}, {status: 200, body: ""})
      expect(hetzner_apis.enable_rescue).to be_nil
    end

    it "raises an error if the ssh key is not set" do
      expect(Config).to receive(:hetzner_ssh_public_key).and_return(nil)
      expect { hetzner_apis.enable_rescue }.to raise_error RuntimeError, "hetzner_ssh_public_key is not set"
    end

    it "raises an error if enabling rescue fails" do
      Excon.stub({path: "/boot/123/rescue", method: :post}, {status: 400, body: ""})
      expect { hetzner_apis.enable_rescue }.to raise_error Excon::Error::BadRequest
    end
  end

  describe "hardware_reset" do
    it "can reset a server" do
      Excon.stub({path: "/reset/123", method: :post, body: "type=hw"}, {status: 200, body: ""})
      expect(hetzner_apis.hardware_reset).to be_nil
    end

    it "raises an error if the reset fails" do
      Excon.stub({path: "/reset/123", method: :post, body: "type=hw"}, {status: 400, body: ""})
      expect { hetzner_apis.hardware_reset }.to raise_error Excon::Error::BadRequest
    end
  end

  describe "add_key" do
    it "can add a key" do
      Excon.stub({path: "/key", method: :post}, {status: 201, body: ""})
      expect(hetzner_apis.add_key("test_key_1", ssh_key)).to be_nil
    end

    it "raises an error if adding a key fails" do
      Excon.stub({path: "/key", method: :post}, {status: 500, body: ""})
      expect { hetzner_apis.add_key("test_key_1", ssh_key) }.to raise_error Excon::Error::InternalServerError
    end
  end

  describe "delete_key" do
    it "can delete a key" do
      Excon.stub({path: "/key/8003339382ac5baa3637f813becce5e4", method: :delete}, {status: 200, body: ""})
      expect(hetzner_apis.delete_key(ssh_key)).to be_nil
    end

    it "raises an error if deleting a key fails" do
      Excon.stub({path: "/key/8003339382ac5baa3637f813becce5e4", method: :delete}, {status: 500, body: ""})
      expect { hetzner_apis.delete_key(ssh_key) }.to raise_error Excon::Error::InternalServerError
    end

    it "regards a missing key as deleted" do
      Excon.stub({path: "/key/8003339382ac5baa3637f813becce5e4", method: :delete}, {status: 404, body: ""})
      expect(hetzner_apis.delete_key(ssh_key)).to be_nil
    end
  end

  describe "get_main_ip4" do
    it "can get the main ip4" do
      Excon.stub({path: "/server/123", method: :get}, {status: 200, body: "{\"server\": {\"server_ip\": \"1.2.3.4\"}}"})
      expect(hetzner_apis.get_main_ip4).to eq "1.2.3.4"
    end

    it "raises an error if getting the main ip4 fails" do
      Excon.stub({path: "/server/123", method: :get}, {status: 404, body: ""})
      expect { hetzner_apis.get_main_ip4 }.to raise_error Excon::Error::NotFound
    end
  end

  describe "pull_data_center" do
    it "can get the dc info" do
      Excon.stub({path: "/server/123", method: :get}, {status: 200, body: "{\"server\": {\"dc\": \"fsn1-dc8\"}}"})
      expect(hetzner_apis.pull_data_center).to eq "fsn1-dc8"
    end

    it "raises an error if getting the dc info fails" do
      Excon.stub({path: "/server/123", method: :get}, {status: 400, body: ""})
      expect { hetzner_apis.pull_data_center }.to raise_error Excon::Error::BadRequest
    end
  end

  describe "hetzner_pull_ips" do
    it "can pull empty data from the API" do
      stub_request(:get, "https://robot-ws.your-server.de/ip").to_return(status: 200, body: JSON.dump([]))
      stub_request(:get, "https://robot-ws.your-server.de/subnet").to_return(status: 200, body: JSON.dump([]))
      stub_request(:get, "https://robot-ws.your-server.de/failover").to_return(status: 200, body: JSON.dump([]))

      expect { hetzner_apis.pull_ips }.not_to raise_error
    end

    it "raises an error if the ip API returns an unexpected status" do
      stub_request(:get, "https://robot-ws.your-server.de/ip").to_return(status: 400, body: JSON.dump([]))
      stub_request(:get, "https://robot-ws.your-server.de/subnet").to_return(status: 200, body: JSON.dump([]))

      expect { hetzner_apis.pull_ips }.to raise_error Excon::Error::BadRequest
    end

    it "raises an error if the subnet API returns an unexpected status" do
      stub_request(:get, "https://robot-ws.your-server.de/subnet").to_return(status: 400, body: JSON.dump([]))

      expect { hetzner_apis.pull_ips }.to raise_error Excon::Error::BadRequest
    end

    it "raises an error if the failover API returns an unexpected status" do
      stub_request(:get, "https://robot-ws.your-server.de/failover").to_return(status: 400, body: JSON.dump([]))
      stub_request(:get, "https://robot-ws.your-server.de/ip").to_return(status: 200, body: JSON.dump([]))
      stub_request(:get, "https://robot-ws.your-server.de/subnet").to_return(status: 200, body: JSON.dump([]))

      expect { hetzner_apis.pull_ips }.to raise_error Excon::Error::BadRequest
    end

    it "can pull data from the API" do
      stub_request(:get, "https://robot-ws.your-server.de/ip").to_return(status: 200, body: JSON.dump([
        {
          "ip" => {
            "ip" => "1.1.1.1",
            "server_ip" => "1.1.1.1",
          },
        },
        {
          "ip" => {
            "ip" => "1.1.2.0",
            "server_ip" => "1.1.1.1",
          },
        },
        {
          "ip" => {
            "ip" => "31.31.31.31",
            "server_ip" => "1.1.1.1",
          },
        },
      ]))
      stub_request(:get, "https://robot-ws.your-server.de/subnet").to_return(status: 200, body: JSON.dump([
        {
          "subnet" => {
            "ip" => "2.2.2.0",
            "mask" => 29,
            "server_ip" => "1.1.1.1",
          },
        },
        {
          "subnet" => {
            "ip" => "3.3.3.0",
            "mask" => 20,
            "server_ip" => "1.1.1.0", # assigned to a different server
          },
        },
        {
          "subnet" => {
            "ip" => "15.15.15.15",
            "mask" => 29,
            "server_ip" => "1.1.1.1",
          },
        },
        {
          "subnet" => {
            "ip" => "30.30.30.30",
            "mask" => 29,
            "server_ip" => "1.1.1.1",
          },
        },
        {
          "subnet" => {
            "ip" => "2a01:4f8:10a:128b::",
            "mask" => 64,
            "server_ip" => "1.1.1.1",
          },
        },
      ]))

      stub_request(:get, "https://robot-ws.your-server.de/failover").to_return(status: 200, body: JSON.dump([
        {
          "failover" => {
            "ip" => "15.15.15.15",
            "mask" => 29,
            "server_ip" => "1.1.1.1",
            "active_server_ip" => "0.0.0.0", # routed to a different server
          },
        },
        {
          "failover" => {
            "ip" => "30.30.30.30",
            "mask" => 29,
            "server_ip" => "1.1.1.1",
            "active_server_ip" => "1.1.1.1",
          },
        },
        {
          "failover" => {
            "ip" => "31.31.31.31",
            "server_ip" => "1.1.1.1",
            "active_server_ip" => "1.1.1.0",
          },
        },
      ]))

      expected = [
        ["1.1.1.1/32", "1.1.1.1", false],
        ["1.1.2.0/32", "1.1.1.1", false],
        ["2.2.2.0/29", "1.1.1.1", false],
        ["30.30.30.30/29", "1.1.1.1", true],
        ["2a01:4f8:10a:128b::/64", "1.1.1.1", false],
      ].map {
        Hosting::HetznerApis::IpInfo.new(ip_address: _1, source_host_ip: _2, is_failover: _3)
      }

      expect(hetzner_apis.pull_ips).to eq expected
    end

    it "handles properly when failover returns 404" do
      stub_request(:get, "https://robot-ws.your-server.de/ip").to_return(status: 200, body: JSON.dump([
        {
          "ip" => {
            "ip" => "1.1.1.1",
            "server_ip" => "1.1.1.1",
          },
        },
        {
          "ip" => {
            "ip" => "1.1.2.0",
            "server_ip" => "1.1.1.1",
          },
        },
      ]))
      stub_request(:get, "https://robot-ws.your-server.de/subnet").to_return(status: 200, body: JSON.dump([
        {
          "subnet" => {
            "ip" => "2.2.2.0",
            "mask" => 29,
            "server_ip" => "1.1.1.1",
          },
        },
        {
          "subnet" => {
            "ip" => "3.3.3.0",
            "mask" => 20,
            "server_ip" => "1.1.1.0", # assigned to a different server
          },
        },
        {
          "subnet" => {
            "ip" => "15.15.15.15",
            "mask" => 29,
            "server_ip" => "1.1.1.1",
          },
        },
        {
          "subnet" => {
            "ip" => "30.30.30.30",
            "mask" => 29,
            "server_ip" => "1.1.1.1",
          },
        },
      ]))

      stub_request(:get, "https://robot-ws.your-server.de/failover").to_return(status: 404)

      expected = [
        ["1.1.1.1/32", "1.1.1.1", false],
        ["1.1.2.0/32", "1.1.1.1", false],
        ["2.2.2.0/29", "1.1.1.1", false],
        ["15.15.15.15/29", "1.1.1.1", false],
        ["30.30.30.30/29", "1.1.1.1", false],
      ].map {
        Hosting::HetznerApis::IpInfo.new(ip_address: _1, source_host_ip: _2, is_failover: _3)
      }

      expect(hetzner_apis.pull_ips).to eq expected
    end
  end

  describe "set_server_name" do
    it "can set the server name" do
      Excon.stub({path: "/server/123", method: :post, body: "server_name=84fe406c-42af-8771-bcde-4a29adc23bb0"}, {status: 200, body: "{}"})
      expect { hetzner_apis.set_server_name("84fe406c-42af-8771-bcde-4a29adc23bb0") }.not_to raise_error
    end

    it "raises an error if setting the server name fails due to invalid input" do
      Excon.stub({path: "/server/123", method: :post, body: "server_name=84fe406c-42af-8771-bcde-4a29adc23bb0"}, {status: 400, body: ""})
      expect { hetzner_apis.set_server_name("84fe406c-42af-8771-bcde-4a29adc23bb0") }.to raise_error Excon::Error::BadRequest
    end

    it "raises an error if setting the server name fails due to not found" do
      Excon.stub({path: "/server/123", method: :post, body: "server_name=84fe406c-42af-8771-bcde-4a29adc23bb0"}, {status: 404, body: ""})
      expect { hetzner_apis.set_server_name("84fe406c-42af-8771-bcde-4a29adc23bb0") }.to raise_error Excon::Error::NotFound
    end
  end
end
