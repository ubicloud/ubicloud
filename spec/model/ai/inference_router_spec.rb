# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe InferenceRouter do
  subject(:inference_router) do
    described_class.new(
      name: "ir-name",
      location_id: Location::HETZNER_FSN1_ID
    ) { _1.id = "b285af98-e140-4ce7-84c8-c31449d23241" }
  end

  describe "#display_states" do
    let(:strand) { instance_double(Strand) }

    before do
      allow(inference_router).to receive(:strand).and_return(strand)
    end

    context "when state is running" do
      before { allow(strand).to receive(:label).and_return("wait") }

      it "returns 'running'" do
        expect(inference_router.display_state).to eq("running")
      end
    end

    context "when state is deleting" do
      before { allow(strand).to receive(:label).and_return("destroy") }

      it "returns 'deleting'" do
        expect(inference_router.display_state).to eq("deleting")
      end
    end

    context "when state is creating" do
      before { allow(strand).to receive(:label).and_return("wait_replicas") }

      it "returns 'creating'" do
        expect(inference_router.display_state).to eq("creating")
      end
    end
  end

  describe "#path" do
    it "returns the correct path" do
      expect(inference_router.path).to eq("/location/eu-central-h1/inference-router/ir-name")
    end
  end
end
