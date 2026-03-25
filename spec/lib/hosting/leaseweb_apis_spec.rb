# frozen_string_literal: true

RSpec.describe Hosting::LeasewebApis do
  let(:vmh) {
    vmh = create_vm_host
    vmh.sshable.update(host: "23.105.171.112")
    vmh
  }
  let(:leaseweb_host) {
    HostProvider.create do |hp|
      hp.id = vmh.id
      hp.server_identifier = "91478"
      hp.provider_name = HostProvider::LEASEWEB_PROVIDER_NAME
    end
  }
  let(:leaseweb_apis) { described_class.new(leaseweb_host) }

  before do
    allow(Config).to receive(:leaseweb_api_key).and_return("test-api-key")
  end

  describe "create_connection" do
    it "sets correct auth header and content type" do
      stub = stub_request(:get, "https://api.leaseweb.com/test")
        .with(headers: {"X-Lsw-Auth" => "test-api-key", "Content-Type" => "application/json"})
        .to_return(status: 200, body: "")

      leaseweb_apis.create_connection.get(path: "/test")
      expect(stub).to have_been_requested
    end
  end

  describe "get_main_ip4" do
    it "returns the main IPv4 address" do
      stub_request(:get, "https://api.leaseweb.com/bareMetals/v2/servers/91478")
        .to_return(status: 200, body: JSON.dump({
          "networkInterfaces" => {"public" => {"ip" => "23.105.171.112"}}
        }))

      expect(leaseweb_apis.get_main_ip4).to eq("23.105.171.112")
    end

    it "raises an error on failure" do
      stub_request(:get, "https://api.leaseweb.com/bareMetals/v2/servers/91478")
        .to_return(status: 404, body: "")

      expect { leaseweb_apis.get_main_ip4 }.to raise_error(Excon::Error::NotFound)
    end
  end

  describe "pull_ips" do
    let(:base_url) { "https://api.leaseweb.com/bareMetals/v2/servers/91478/ips" }

    it "fetches and returns PUBLIC NORMAL_IP records" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.171.112", "prefixLength" => 26, "gateway" => "23.105.171.126", "mainIp" => true, "networkType" => "PUBLIC", "type" => "NORMAL_IP"}
          ],
          "_metadata" => {"totalCount" => 1}
        }))

      result = leaseweb_apis.pull_ips
      expect(result.length).to eq(1)
      expect(result[0].ip_address).to eq("23.105.171.112/32")
      expect(result[0].source_host_ip).to eq("23.105.171.112")
      expect(result[0].is_failover).to be false
      expect(result[0].gateway).to eq("23.105.171.126")
      expect(result[0].mask).to eq(26)
    end

    it "handles pagination across multiple pages" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.171.112", "prefixLength" => 26, "gateway" => "23.105.171.126", "mainIp" => true, "networkType" => "PUBLIC", "type" => "NORMAL_IP"}
          ],
          "_metadata" => {"totalCount" => 2}
        }))

      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 50})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.176.1", "prefixLength" => 29, "gateway" => "", "mainIp" => false, "networkType" => "PUBLIC", "type" => "NORMAL_IP"}
          ],
          "_metadata" => {"totalCount" => 2}
        }))

      result = leaseweb_apis.pull_ips
      expect(result.length).to eq(2)
    end

    it "filters out non-PUBLIC IPs such as REMOTE_MANAGEMENT" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.171.112", "prefixLength" => 26, "gateway" => "23.105.171.126", "mainIp" => true, "networkType" => "PUBLIC", "type" => "NORMAL_IP"},
            {"ip" => "10.0.0.1", "prefixLength" => 24, "gateway" => "10.0.0.254", "mainIp" => false, "networkType" => "REMOTE_MANAGEMENT", "type" => "NORMAL_IP"}
          ],
          "_metadata" => {"totalCount" => 2}
        }))

      result = leaseweb_apis.pull_ips
      expect(result.length).to eq(1)
      expect(result[0].ip_address).to eq("23.105.171.112/32")
    end

    it "filters out infrastructure IP types (NETWORK, GATEWAY, BROADCAST, ROUTER1, ROUTER2)" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.171.112", "prefixLength" => 26, "gateway" => "23.105.171.126", "mainIp" => true, "networkType" => "PUBLIC", "type" => "NORMAL_IP"},
            {"ip" => "23.105.176.0", "prefixLength" => 29, "gateway" => "", "mainIp" => false, "networkType" => "PUBLIC", "type" => "NETWORK"},
            {"ip" => "23.105.176.6", "prefixLength" => 29, "gateway" => "", "mainIp" => false, "networkType" => "PUBLIC", "type" => "GATEWAY"},
            {"ip" => "23.105.176.7", "prefixLength" => 29, "gateway" => "", "mainIp" => false, "networkType" => "PUBLIC", "type" => "BROADCAST"},
            {"ip" => "23.105.176.4", "prefixLength" => 29, "gateway" => "", "mainIp" => false, "networkType" => "PUBLIC", "type" => "ROUTER1"},
            {"ip" => "23.105.176.5", "prefixLength" => 29, "gateway" => "", "mainIp" => false, "networkType" => "PUBLIC", "type" => "ROUTER2"}
          ],
          "_metadata" => {"totalCount" => 6}
        }))

      result = leaseweb_apis.pull_ips
      expect(result.length).to eq(1)
      expect(result[0].ip_address).to eq("23.105.171.112/32")
    end

    it "normalizes IPv6 underscore format" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.171.112", "prefixLength" => 26, "gateway" => "23.105.171.126", "mainIp" => true, "networkType" => "PUBLIC", "type" => "NORMAL_IP"},
            {"ip" => "2607:f5b7:1:30:9::_112", "prefixLength" => 64, "gateway" => "2607:f5b7:1:30::1", "mainIp" => false, "networkType" => "PUBLIC", "type" => "NORMAL_IP"}
          ],
          "_metadata" => {"totalCount" => 2}
        }))

      result = leaseweb_apis.pull_ips
      ipv6_result = result.find { |r| r.ip_address.include?(":") }
      expect(ipv6_result.ip_address).to eq("2607:f5b7:1:30:9::/112")
      expect(ipv6_result.gateway).to eq("2607:f5b7:1:30::1")
      expect(ipv6_result.mask).to eq(112)
      expect(ipv6_result.source_host_ip).to eq("23.105.171.112")
      expect(ipv6_result.is_failover).to be false
    end

    it "treats main IP with gateway as /32" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.171.112", "prefixLength" => 26, "gateway" => "23.105.171.126", "mainIp" => true, "networkType" => "PUBLIC", "type" => "NORMAL_IP"}
          ],
          "_metadata" => {"totalCount" => 1}
        }))

      result = leaseweb_apis.pull_ips
      expect(result[0].ip_address).to eq("23.105.171.112/32")
      expect(result[0].gateway).to eq("23.105.171.126")
      expect(result[0].mask).to eq(26)
    end

    it "treats non-main IP with explicit gateway as /32" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.171.112", "prefixLength" => 26, "gateway" => "23.105.171.126", "mainIp" => true, "networkType" => "PUBLIC", "type" => "NORMAL_IP"},
            {"ip" => "5.6.7.8", "prefixLength" => 24, "gateway" => "5.6.7.1", "mainIp" => false, "networkType" => "PUBLIC", "type" => "NORMAL_IP"}
          ],
          "_metadata" => {"totalCount" => 2}
        }))

      result = leaseweb_apis.pull_ips
      extra_ip = result.find { |r| r.ip_address == "5.6.7.8/32" }
      expect(extra_ip).not_to be_nil
      expect(extra_ip.gateway).to eq("5.6.7.1")
      expect(extra_ip.mask).to eq(24)
    end

    it "groups subnet IPs without gateway into network CIDR" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.171.112", "prefixLength" => 26, "gateway" => "23.105.171.126", "mainIp" => true, "networkType" => "PUBLIC", "type" => "NORMAL_IP"},
            {"ip" => "23.105.176.1", "prefixLength" => 29, "gateway" => "", "mainIp" => false, "networkType" => "PUBLIC", "type" => "NORMAL_IP"},
            {"ip" => "23.105.176.2", "prefixLength" => 29, "gateway" => "", "mainIp" => false, "networkType" => "PUBLIC", "type" => "NORMAL_IP"},
            {"ip" => "23.105.176.3", "prefixLength" => 29, "gateway" => "", "mainIp" => false, "networkType" => "PUBLIC", "type" => "NORMAL_IP"}
          ],
          "_metadata" => {"totalCount" => 4}
        }))

      result = leaseweb_apis.pull_ips
      subnet_result = result.find { |r| r.ip_address.include?("/29") }
      expect(subnet_result).not_to be_nil
      expect(subnet_result.ip_address).to eq("23.105.176.0/29")
      expect(subnet_result.gateway).to be_nil
      expect(subnet_result.mask).to eq(29)
      expect(subnet_result.source_host_ip).to eq("23.105.171.112")
    end

    it "normalizes empty gateway string to nil" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.171.112", "prefixLength" => 26, "gateway" => "", "mainIp" => true, "networkType" => "PUBLIC", "type" => "NORMAL_IP"}
          ],
          "_metadata" => {"totalCount" => 1}
        }))

      result = leaseweb_apis.pull_ips
      expect(result[0].gateway).to be_nil
    end

    it "normalizes nil gateway to nil" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.171.112", "prefixLength" => 26, "gateway" => nil, "mainIp" => true, "networkType" => "PUBLIC", "type" => "NORMAL_IP"}
          ],
          "_metadata" => {"totalCount" => 1}
        }))

      result = leaseweb_apis.pull_ips
      expect(result[0].gateway).to be_nil
    end

    it "returns correct IpInfo struct fields for all IP types" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.171.112", "prefixLength" => 26, "gateway" => "23.105.171.126", "mainIp" => true, "networkType" => "PUBLIC", "type" => "NORMAL_IP"},
            {"ip" => "2607:f5b7:1:30:9::_112", "prefixLength" => 64, "gateway" => "2607:f5b7:1:30::1", "mainIp" => false, "networkType" => "PUBLIC", "type" => "NORMAL_IP"},
            {"ip" => "23.105.176.1", "prefixLength" => 29, "gateway" => "", "mainIp" => false, "networkType" => "PUBLIC", "type" => "NORMAL_IP"},
            {"ip" => "23.105.176.2", "prefixLength" => 29, "gateway" => "", "mainIp" => false, "networkType" => "PUBLIC", "type" => "NORMAL_IP"}
          ],
          "_metadata" => {"totalCount" => 4}
        }))

      expected = [
        described_class::IpInfo.new(ip_address: "23.105.171.112/32", source_host_ip: "23.105.171.112", is_failover: false, gateway: "23.105.171.126", mask: 26),
        described_class::IpInfo.new(ip_address: "2607:f5b7:1:30:9::/112", source_host_ip: "23.105.171.112", is_failover: false, gateway: "2607:f5b7:1:30::1", mask: 112),
        described_class::IpInfo.new(ip_address: "23.105.176.0/29", source_host_ip: "23.105.171.112", is_failover: false, gateway: nil, mask: 29)
      ]

      expect(leaseweb_apis.pull_ips).to eq(expected)
    end

    it "handles empty IP list" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [],
          "_metadata" => {"totalCount" => 0}
        }))

      expect(leaseweb_apis.pull_ips).to eq([])
    end

    it "raises an error on HTTP failure" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 500, body: "")

      expect { leaseweb_apis.pull_ips }.to raise_error(Excon::Error::InternalServerError)
    end

    it "handles IPv6 with underscore format and no gateway" do
      stub_request(:get, base_url)
        .with(query: {limit: 50, offset: 0})
        .to_return(status: 200, body: JSON.dump({
          "ips" => [
            {"ip" => "23.105.171.112", "prefixLength" => 26, "gateway" => "23.105.171.126", "mainIp" => true, "networkType" => "PUBLIC", "type" => "NORMAL_IP"},
            {"ip" => "2607:f5b7:1:30:9::_112", "prefixLength" => 64, "gateway" => "", "mainIp" => false, "networkType" => "PUBLIC", "type" => "NORMAL_IP"}
          ],
          "_metadata" => {"totalCount" => 2}
        }))

      result = leaseweb_apis.pull_ips
      ipv6_result = result.find { |r| r.ip_address.include?(":") }
      expect(ipv6_result.gateway).to be_nil
    end
  end
end
