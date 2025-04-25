# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe InferenceEndpoint do
  subject(:inference_endpoint) do
    described_class.new(
      name: "ie-name",
      location_id: Location::HETZNER_FSN1_ID,
      model_name: "model-name"
    ) { it.id = "c76fcd0c-3fb0-40cc-8732-d71869ee1341" }
  end

  describe "#display_states" do
    let(:strand) { instance_double(Strand) }

    before do
      allow(inference_endpoint).to receive(:strand).and_return(strand)
    end

    context "when state is running" do
      before { allow(strand).to receive(:label).and_return("wait") }

      it "returns 'running'" do
        expect(inference_endpoint.display_state).to eq("running")
      end
    end

    context "when state is deleting" do
      before { allow(strand).to receive(:label).and_return("destroy") }

      it "returns 'deleting'" do
        expect(inference_endpoint.display_state).to eq("deleting")
      end
    end

    context "when state is creating" do
      before { allow(strand).to receive(:label).and_return("wait_replicas") }

      it "returns 'creating'" do
        expect(inference_endpoint.display_state).to eq("creating")
      end
    end
  end

  describe "#path" do
    it "returns the correct path" do
      expect(inference_endpoint.path).to eq("/location/eu-central-h1/inference-endpoint/ie-name")
    end
  end

  shared_examples "chat completion request" do |development|
    let(:http) { instance_double(Net::HTTP, read_timeout: 30) }
    let(:load_balancer) { instance_double(LoadBalancer, health_check_protocol: "https") }

    before do
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=).with(true)
      allow(http).to receive(:read_timeout=).with(30)
      allow(inference_endpoint).to receive(:load_balancer).and_return(load_balancer)
    end

    it "sends the request correctly" do
      if development
        allow(Config).to receive(:development?).and_return(true)
        allow(http).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_NONE)
      end

      expect(http).to receive(:request) do |req|
        expect(req).to be_an_instance_of(Net::HTTP::Post)
        expect(req["Content-Type"]).to eq("application/json")
        expect(req["Authorization"]).to eq("Bearer api_key")
        expect(req.body).to eq({model: "model-name", messages: [{role: "user", content: "what's a common greeting?"}]}.to_json)
      end.and_return("hello")

      expect(inference_endpoint.chat_completion_request("what's a common greeting?", "hostname", "api_key")).to eq("hello")
    end
  end

  describe "#chat_completion_request" do
    context "when production" do
      it_behaves_like "chat completion request", false
    end

    context "when development" do
      it_behaves_like "chat completion request", true
    end
  end
end
