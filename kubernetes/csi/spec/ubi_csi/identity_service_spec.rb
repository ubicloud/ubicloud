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
    let(:request) { Csi::V1::GetPluginInfoRequest.new }
    let(:call) { instance_double("GRPC::ActiveCall") }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("test-uuid")
    end

    it "returns plugin information with correct name" do
      response = service.get_plugin_info(request, call)
      expect(response.name).to eq("csi.ubicloud.com")
      expect(response.vendor_version).to eq("0.1.0")
    end

    it "logs request and response" do
      expect(service).to receive(:log_with_id).with("test-uuid", /get_plugin_info request/)
      expect(service).to receive(:log_with_id).with("test-uuid", /get_plugin_info response/)
      service.get_plugin_info(request, call)
    end
  end

  describe "#get_plugin_capabilities" do
    let(:request) { Csi::V1::GetPluginCapabilitiesRequest.new }
    let(:call) { instance_double("GRPC::ActiveCall") }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("test-uuid")
    end

    it "returns plugin capabilities" do
      response = service.get_plugin_capabilities(request, call)
      expect(response.capabilities.length).to eq(2)
    end

    it "includes CONTROLLER_SERVICE capability" do
      response = service.get_plugin_capabilities(request, call)
      controller_capability = response.capabilities.find do |cap|
        cap.service.type == :CONTROLLER_SERVICE
      end
      expect(controller_capability).not_to be_nil
    end

    it "includes VOLUME_ACCESSIBILITY_CONSTRAINTS capability" do
      response = service.get_plugin_capabilities(request, call)
      accessibility_capability = response.capabilities.find do |cap|
        cap.service.type == :VOLUME_ACCESSIBILITY_CONSTRAINTS
      end
      expect(accessibility_capability).not_to be_nil
    end

    it "logs request and response" do
      expect(service).to receive(:log_with_id).with("test-uuid", /get_plugin_capabilities request/)
      expect(service).to receive(:log_with_id).with("test-uuid", /get_plugin_capabilities response/)
      service.get_plugin_capabilities(request, call)
    end
  end

  describe "#probe" do
    let(:request) { Csi::V1::ProbeRequest.new }
    let(:call) { instance_double("GRPC::ActiveCall") }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("test-uuid")
    end

    it "returns ready status as true" do
      response = service.probe(request, call)
      expect(response.ready.value).to be true
    end

    it "logs request and response" do
      expect(service).to receive(:log_with_id).with("test-uuid", /probe request/)
      expect(service).to receive(:log_with_id).with("test-uuid", /probe response/)
      service.probe(request, call)
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

