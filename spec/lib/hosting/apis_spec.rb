# frozen_string_literal: true

RSpec.describe Hosting::Apis do
  let(:vm_host) {
    instance_double(
      VmHost,
      ubid: "vhgkz40v22ny2qkf4maddr8xv1",
      provider: hetzner_host,
      provider_name: HostProvider::HETZNER_PROVIDER_NAME,
    )
  }
  let(:hetzner_apis) { instance_double(Hosting::HetznerApis, pull_ips: []) }
  let(:hetzner_host) {
    instance_double(
      HostProvider,
      connection_string: "str",
      user: "user1", password: "pass",
      api: hetzner_apis,
      server_identifier: 123,
      provider_name: HostProvider::HETZNER_PROVIDER_NAME,
    )
  }

  let(:leaseweb_vm_host) {
    instance_double(
      VmHost,
      ubid: "vhlswtest00000000000000001",
      provider: leaseweb_host,
      provider_name: HostProvider::LEASEWEB_PROVIDER_NAME
    )
  }
  let(:leaseweb_apis) { instance_double(Hosting::LeasewebApis, pull_ips: []) }
  let(:leaseweb_host) {
    instance_double(
      HostProvider,
      connection_string: "https://api.leaseweb.com",
      user: nil, password: nil,
      api: leaseweb_apis,
      server_identifier: "91478",
      provider_name: HostProvider::LEASEWEB_PROVIDER_NAME
    )
  }

  describe "pull_ips" do
    it "can pull data from the Hetzner API" do
      expect(hetzner_apis).to receive(:pull_ips).and_return([])
      described_class.pull_ips(vm_host)
    end

    it "can pull data from the Leaseweb API" do
      expect(leaseweb_apis).to receive(:pull_ips).and_return([])
      described_class.pull_ips(leaseweb_vm_host)
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider_name).and_return("unknown").at_least(:once)
      expect { described_class.pull_ips(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end

  describe "reimage_server" do
    it "can reimage a Hetzner server" do
      expect(hetzner_apis).to receive(:reimage).with(123).and_return(true)
      described_class.reimage_server(vm_host)
    end

    it "raises an error for Leaseweb provider" do
      expect { described_class.reimage_server(leaseweb_vm_host) }.to raise_error RuntimeError, "Leaseweb provider does not support reimage_server"
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider_name).and_return("unknown").at_least(:once)
      expect { described_class.reimage_server(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end

  describe "hardware_reset_server" do
    it "can hardware reset a Hetzner server" do
      expect(hetzner_apis).to receive(:reset).with(123).and_return(true)
      described_class.hardware_reset_server(vm_host)
    end

    it "raises an error for Leaseweb provider" do
      expect { described_class.hardware_reset_server(leaseweb_vm_host) }.to raise_error RuntimeError, "Leaseweb provider does not support hardware_reset_server"
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider_name).and_return("unknown").at_least(:once)
      expect { described_class.hardware_reset_server(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end

  describe "pull_dc" do
    it "can pull dc of a Hetzner server" do
      expect(hetzner_apis).to receive(:pull_dc).with(123).and_return("dc1")
      described_class.pull_data_center(vm_host)
    end

    it "returns nil for Leaseweb provider" do
      expect(described_class.pull_data_center(leaseweb_vm_host)).to be_nil
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider_name).and_return("unknown").at_least(:once)
      expect { described_class.pull_data_center(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end

  describe "set_server_name" do
    it "can set Hetzner server name" do
      expect(hetzner_apis).to receive(:set_server_name).with(123, "vhgkz40v22ny2qkf4maddr8xv1").and_return(nil)
      described_class.set_server_name(vm_host)
    end

    it "raises an error for Leaseweb provider" do
      expect { described_class.set_server_name(leaseweb_vm_host) }.to raise_error RuntimeError, "Leaseweb provider does not support set_server_name"
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider_name).and_return("unknown").at_least(:once)
      expect { described_class.set_server_name(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end
end
