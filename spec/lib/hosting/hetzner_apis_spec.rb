# frozen_string_literal: true

RSpec.describe Hosting::HetznerApis do
  let(:vm_host) {
    instance_double(
      VmHost,
      provider: HetznerHost::PROVIDER_NAME,
      sshable: instance_double(Sshable, host: "1.1.1.1")
    )
  }
  let(:hetzner_host) { instance_double(HetznerHost, connection_string: "https://robot-ws.your-server.de", user: "user1", password: "pass", vm_host: vm_host) }
  let(:hetzner_apis) { described_class.new(hetzner_host) }

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

      expect { hetzner_apis.pull_ips }.to raise_error RuntimeError, "unexpected status 400"
    end

    it "raises an error if the subnet API returns an unexpected status" do
      stub_request(:get, "https://robot-ws.your-server.de/subnet").to_return(status: 400, body: JSON.dump([]))

      expect { hetzner_apis.pull_ips }.to raise_error RuntimeError, "unexpected status 400"
    end

    it "raises an error if the failover API returns an unexpected status" do
      stub_request(:get, "https://robot-ws.your-server.de/failover").to_return(status: 400, body: JSON.dump([]))
      stub_request(:get, "https://robot-ws.your-server.de/ip").to_return(status: 200, body: JSON.dump([]))
      stub_request(:get, "https://robot-ws.your-server.de/subnet").to_return(status: 200, body: JSON.dump([]))

      expect { hetzner_apis.pull_ips }.to raise_error RuntimeError, "unexpected status 400"
    end

    it "can pull data from the API" do
      stub_request(:get, "https://robot-ws.your-server.de/ip").to_return(status: 200, body: JSON.dump([
        {
          "ip" => {
            "ip" => "1.1.1.1",
            "server_ip" => "1.1.1.1"
          }
        },
        {
          "ip" => {
            "ip" => "1.1.2.0",
            "server_ip" => "1.1.1.1"
          }
        }
      ]))
      stub_request(:get, "https://robot-ws.your-server.de/subnet").to_return(status: 200, body: JSON.dump([
        {
          "subnet" => {
            "ip" => "2.2.2.0",
            "mask" => 29,
            "server_ip" => "1.1.1.1"
          }
        },
        {
          "subnet" => {
            "ip" => "3.3.3.0",
            "mask" => 20,
            "server_ip" => "1.1.1.0" # assigned to a different server
          }
        },
        {
          "subnet" => {
            "ip" => "15.15.15.15",
            "mask" => 29,
            "server_ip" => "1.1.1.1"
          }
        },
        {
          "subnet" => {
            "ip" => "30.30.30.30",
            "mask" => 29,
            "server_ip" => "1.1.1.1"
          }
        }
      ]))

      stub_request(:get, "https://robot-ws.your-server.de/failover").to_return(status: 200, body: JSON.dump([
        {
          "failover" => {
            "ip" => "15.15.15.15",
            "mask" => 29,
            "server_ip" => "1.1.1.1",
            "active_server_ip" => "0.0.0.0" # routed to a different server
          }
        },
        {
          "failover" => {
            "ip" => "30.30.30.30",
            "mask" => 29,
            "server_ip" => "1.1.1.1",
            "active_server_ip" => "1.1.1.1"
          }
        }
      ]))

      expected = [
        ["1.1.1.1/32", "1.1.1.1", false],
        ["1.1.2.0/32", "1.1.1.1", false],
        ["2.2.2.0/29", "1.1.1.1", false],
        ["30.30.30.30/29", "1.1.1.1", true]
      ].map {
        Hosting::HetznerApis::IpInfo.new(ip_address: _1, source_host_ip: _2, is_failover: _3)
      }

      expect(hetzner_apis.pull_ips).to eq expected
    end
  end
end
