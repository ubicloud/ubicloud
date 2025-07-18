# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Csi::V1::IdentityService do
  let(:service) { described_class.new }

  describe "#log_with_id" do
    it "logs messages with request ID" do
      expect { service.log_with_id("test-id", "test message") }.not_to raise_error
    end
  end

  describe "#get_plugin_info" do
    let(:request) { instance_double("GetPluginInfoRequest") }
    let(:call) { instance_double("GRPC::ActiveCall") }

    before do
      allow(request).to receive(:inspect).and_return("test request")
      allow(SecureRandom).to receive(:uuid).and_return("test-uuid")
    end

    it "returns plugin information" do
      response = service.get_plugin_info(request, call)
      expect(response).to be_a(Csi::V1::GetPluginInfoResponse)
    end

    it "sets the correct plugin name" do
      response = service.get_plugin_info(request, call)
      expect(response.name).to eq("csi.ubicloud.com")
    end
  end

  describe "class inheritance" do
    it "inherits from Identity::Service" do
      expect(described_class.superclass).to eq(Csi::V1::Identity::Service)
    end
  end

  describe "LOGGER constant" do
    it "is defined" do
      expect(described_class::LOGGER).to be_a(Logger)
    end
  end
end

