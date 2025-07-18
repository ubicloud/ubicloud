# frozen_string_literal: true

require "logger"
require "spec_helper"

RSpec.describe Csi::V1::IdentityService do
  let(:service) { described_class.new(logger: Logger.new($stdout)) }
  let(:call) { instance_double(GRPC::ActiveCall) }

  describe "#log_with_id" do
    it "logs messages with request ID" do
      expect { service.log_with_id("test-id", "test message") }.not_to raise_error
    end
  end

  describe "#get_plugin_info" do
    before { expect(SecureRandom).to receive(:uuid).and_return("test-uuid") }

    it "returns plugin information" do
      request = Csi::V1::GetPluginInfoRequest.new
      response = service.get_plugin_info(request, call)
      expect(response.name).to eq("csi.ubicloud.com")
      expect(response.vendor_version).to eq("0.1.0")
    end
  end

  describe "#get_plugin_capabilities" do
    before { expect(SecureRandom).to receive(:uuid).and_return("test-uuid") }

    it "returns CONTROLLER_SERVICE and VOLUME_ACCESSIBILITY_CONSTRAINTS capabilities" do
      request = Csi::V1::GetPluginCapabilitiesRequest.new
      response = service.get_plugin_capabilities(request, call)
      capability_types = response.capabilities.map { |cap| cap.service.type }
      expect(capability_types).to contain_exactly(:CONTROLLER_SERVICE, :VOLUME_ACCESSIBILITY_CONSTRAINTS)
    end
  end

  describe "#probe" do
    before { expect(SecureRandom).to receive(:uuid).and_return("test-uuid") }

    it "returns ready status as true" do
      request = Csi::V1::ProbeRequest.new
      response = service.probe(request, call)
      expect(response.ready.value).to be true
    end
  end
end
