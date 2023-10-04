# frozen_string_literal: true

RSpec.describe Hosting::Apis do
  let(:vm_host) {
    instance_double(
      VmHost,
      provider: HetznerHost::PROVIDER_NAME,
      hetzner_host: hetzner_host
    )
  }
  let(:connection) { instance_double(Excon::Connection) }
  let(:hetzner_apis) { instance_double(Hosting::HetznerApis, pull_ips: []) }
  let(:hetzner_host) {
    instance_double(
      HetznerHost,
      connection_string: "str",
      user: "user1", password: "pass",
      api: hetzner_apis,
      server_identifier: 123
    )
  }

  describe "pull_ips" do
    it "can pull data from the API" do
      expect(hetzner_apis).to receive(:pull_ips).and_return([])
      described_class.pull_ips(vm_host)
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider).and_return("unknown").at_least(:once)
      expect { described_class.pull_ips(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end

  describe "reset_server" do
    it "can reset a server" do
      expect(hetzner_apis).to receive(:reset).with(123).and_return(true)
      described_class.reset_server(vm_host)
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider).and_return("unknown").at_least(:once)
      expect { described_class.reset_server(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end

  describe "pull_dc" do
    it "can set dc of a server" do
      expect(hetzner_apis).to receive(:pull_dc).with(123).and_return("dc1")
      described_class.pull_data_center(vm_host)
    end

    it "raises an error if the provider is unknown" do
      expect(vm_host).to receive(:provider).and_return("unknown").at_least(:once)
      expect { described_class.pull_data_center(vm_host) }.to raise_error RuntimeError, "unknown provider unknown"
    end
  end
end
