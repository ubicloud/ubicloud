# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Csi::V1::NodeService do
  let(:service) { described_class.new }

  describe "constants" do
    it "defines MAX_VOLUMES_PER_NODE" do
      expect(described_class::MAX_VOLUMES_PER_NODE).to eq(8)
    end

    it "defines VOLUME_BASE_PATH" do
      expect(described_class::VOLUME_BASE_PATH).to eq("/var/lib/ubicsi")
    end

    it "defines LOGGER" do
      expect(described_class::LOGGER).to be_a(Logger)
    end

    it "defines OLD_PV_NAME_ANNOTATION_KEY" do
      expect(described_class::OLD_PV_NAME_ANNOTATION_KEY).to eq("csi.ubicloud.com/old-pv-name")
    end

    it "defines OLD_PVC_OBJECT_ANNOTATION_KEY" do
      expect(described_class::OLD_PVC_OBJECT_ANNOTATION_KEY).to eq("csi.ubicloud.com/old-pvc-object")
    end
  end

  describe "#log_with_id" do
    it "logs messages with request ID and service identifier" do
      expect { service.log_with_id("test-id", "test message") }.not_to raise_error
    end
  end

  describe "#node_name" do
    context "when NODE_ID environment variable is set" do
      before do
        allow(ENV).to receive(:[]).with("NODE_ID").and_return("test-node")
      end

      it "returns the NODE_ID environment variable" do
        expect(service.node_name).to eq("test-node")
      end
    end

    context "when NODE_ID environment variable is not set" do
      before do
        allow(ENV).to receive(:[]).with("NODE_ID").and_return(nil)
      end

      it "returns nil" do
        expect(service.node_name).to be_nil
      end
    end
  end

  describe "class inheritance" do
    it "inherits from Node::Service" do
      expect(described_class.superclass).to eq(Csi::V1::Node::Service)
    end
  end
end

