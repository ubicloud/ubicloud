# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe HetznerHost do
  subject(:hetzner_host) { described_class.new }

  let(:vm_host) {
    instance_double(
      VmHost,
      provider: HetznerHost::PROVIDER_NAME,
      hetzner_host: hetzner_host
    )
  }

  describe "connection_string" do
    it "returns the connection string" do
      expect(hetzner_host.connection_string).to eq "https://robot-ws.your-server.de"
    end
  end

  describe "user" do
    it "returns the user" do
      expect(hetzner_host.user).to eq "user1"
    end
  end

  describe "password" do
    it "returns the password" do
      expect(hetzner_host.password).to eq "pass"
    end
  end

  describe "api" do
    it "returns the api" do
      expect(hetzner_host.api).to be_a Hosting::HetznerApis
    end
  end
end
