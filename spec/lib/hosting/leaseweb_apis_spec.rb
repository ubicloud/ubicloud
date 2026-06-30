# frozen_string_literal: true

RSpec.describe Hosting::LeasewebApis do
  let(:leaseweb_apis) do
    vmh = create_vm_host
    provider = HostProvider.create do
      it.id = vmh.id
      it.server_identifier = "123"
      it.provider_name = HostProvider::LEASEWEB_PROVIDER_NAME
    end
    described_class.new(provider)
  end

  before do
    allow(Config).to receive_messages(
      leaseweb_connection_string: "https://api.leaseweb.com",
      leaseweb_api_key: "key123",
    )
  end

  describe "hardware_reset" do
    it "can power cycle a server" do
      Excon.stub({path: "/bareMetals/v2/servers/123/powerCycle", method: :post}, {status: 204, body: ""})
      expect(leaseweb_apis.hardware_reset).to be_nil
    end
  end

  describe "set_server_name" do
    it "updates the server reference" do
      Excon.stub({path: "/bareMetals/v2/servers/123", method: :put, body: JSON.generate(reference: "vh123")}, {status: 204, body: ""})
      expect { leaseweb_apis.set_server_name("vh123") }.not_to raise_error
    end
  end

  describe "pull_data_center" do
    it "returns the site and suite" do
      Excon.stub({path: "/bareMetals/v2/servers/123", method: :get}, {status: 200, body: JSON.generate(location: {site: "AMS-02", suite: "HALL1"})})
      expect(leaseweb_apis.pull_data_center).to eq "AMS-02-HALL1"
    end
  end

  describe "unimplemented operations" do
    it "does not respond to operations leaseweb does not implement" do
      [:pull_ips, :reimage, :get_main_ip4, :add_key, :delete_key].each do |operation|
        expect(leaseweb_apis).not_to respond_to(operation)
      end
    end
  end
end
