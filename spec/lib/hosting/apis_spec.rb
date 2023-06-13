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
  let(:hetzner_host) { instance_double(HetznerHost, connection_string: "str", user: "user1", password: "pass", api: hetzner_apis) }

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
end
