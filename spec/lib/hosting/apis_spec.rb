# frozen_string_literal: true

RSpec.describe Hosting::Apis do
  let(:vm_host) {
    instance_double(
      VmHost,
      ubid: "vhgkz40v22ny2qkf4maddr8xv1",
      provider: hetzner_host,
      provider_name: HostProvider::HETZNER_PROVIDER_NAME
    )
  }
  let(:connection) { instance_double(Excon::Connection) }
  let(:hetzner_apis) { instance_double(Hosting::HetznerApis, pull_ips: []) }
  let(:hetzner_host) {
    instance_double(
      HostProvider,
      connection_string: "str",
      user: "user1", password: "pass",
      api: hetzner_apis,
      server_identifier: 123,
      provider_name: HostProvider::HETZNER_PROVIDER_NAME
    )
  }

  describe "pull_ips" do
    it "can pull data from the API" do
      expect(hetzner_apis).to receive(:pull_ips).and_return([])
      described_class.pull_ips(vm_host)
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider_name).and_return("unknown").at_least(:once)
      expect { described_class.pull_ips(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end

  describe "reimage_server" do
    it "can reimage a server" do
      expect(hetzner_apis).to receive(:reimage).with(123).and_return(true)
      described_class.reimage_server(vm_host)
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider_name).and_return("unknown").at_least(:once)
      expect { described_class.reimage_server(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end

  describe "hardware_reset_server" do
    it "can hardware reset a server" do
      expect(hetzner_apis).to receive(:reset).with(123).and_return(true)
      described_class.hardware_reset_server(vm_host)
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider_name).and_return("unknown").at_least(:once)
      expect { described_class.hardware_reset_server(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end

  describe "pull_dc" do
    it "can set dc of a server" do
      expect(hetzner_apis).to receive(:pull_dc).with(123).and_return("dc1")
      described_class.pull_data_center(vm_host)
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider_name).and_return("unknown").at_least(:once)
      expect { described_class.pull_data_center(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end

  describe "set_server_name" do
    it "can set server name" do
      expect(hetzner_apis).to receive(:set_server_name).with(123, "vhgkz40v22ny2qkf4maddr8xv1").and_return(nil)
      described_class.set_server_name(vm_host)
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider_name).and_return("unknown").at_least(:once)
      expect { described_class.set_server_name(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end
end
