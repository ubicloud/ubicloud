# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Csi::V1::ControllerService do
  let(:service) { described_class.new }

  describe "constants" do
    it "defines MAX_VOLUME_SIZE" do
      expect(described_class::MAX_VOLUME_SIZE).to eq(2 * 1024 * 1024 * 1024)
    end

    it "defines LOGGER" do
      expect(described_class::LOGGER).to be_a(Logger)
    end
  end

  describe "#initialize" do
    it "initializes with empty volume store" do
      expect(service.instance_variable_get(:@volume_store)).to eq({})
    end

    it "initializes with a mutex" do
      expect(service.instance_variable_get(:@mutex)).to be_a(Mutex)
    end
  end

  describe "#log_with_id" do
    it "logs messages with request ID" do
      expect { service.log_with_id("test-id", "test message") }.not_to raise_error
    end
  end

  describe "#run_cmd" do
    let(:cmd) { ["echo", "test"] }

    it "runs command without request ID" do
      allow(Open3).to receive(:capture2e).with(*cmd).and_return(["output", instance_double("Process::Status")])
      expect { service.run_cmd(*cmd) }.not_to raise_error
    end

    it "runs command with request ID" do
      allow(Open3).to receive(:capture2e).with(*cmd).and_return(["output", instance_double("Process::Status")])
      expect { service.run_cmd(*cmd, req_id: "test-id") }.not_to raise_error
    end
  end

  describe "#controller_get_capabilities" do
    let(:request) { Csi::V1::ControllerGetCapabilitiesRequest.new }
    let(:call) { instance_double("GRPC::ActiveCall") }

    before do
      allow(SecureRandom).to receive(:uuid).and_return("test-uuid")
    end

    it "responds to controller_get_capabilities" do
      expect(service).to respond_to(:controller_get_capabilities)
    end
  end

  describe "class inheritance" do
    it "inherits from Controller::Service" do
      expect(described_class.superclass).to eq(Csi::V1::Controller::Service)
    end
  end
end

