# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe HostProvider do
  subject(:hetzner_host) {
    described_class.new do |hp|
      hp.provider_name = HostProvider::HETZNER_PROVIDER_NAME
      hp.server_identifier = "123"
      hp.id = "1d422893-2955-4c2c-b41c-f2ec70bcd60d"
    end
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
