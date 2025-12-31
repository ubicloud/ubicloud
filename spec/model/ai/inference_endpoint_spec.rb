# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe InferenceEndpoint do
  subject(:inference_endpoint) do
    described_class.create(
      name: "ie-name",
      location_id: Location::HETZNER_FSN1_ID,
      model_name: "model-name",
      project_id: project.id,
      is_public: false,
      boot_image: "image",
      vm_size: "size",
      storage_volumes: [],
      engine: "vllm",
      engine_params: "",
      replica_count: 1,
      load_balancer_id: load_balancer.id,
      private_subnet_id: private_subnet.id
    )
  end

  let(:project) { Project.create(name: "test-project") }
  let(:private_subnet) do
    PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID,
      net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26",
      state: "waiting", project_id: project.id)
  end
  let(:load_balancer) do
    LoadBalancer.create(
      name: "lb",
      health_check_protocol: "https",
      health_check_endpoint: "/health",
      project_id: project.id,
      private_subnet_id: private_subnet.id
    )
  end

  describe "#display_states" do
    let!(:strand) { Strand.create_with_id(inference_endpoint, prog: "Ai::InferenceEndpointNexus", label: "wait") }

    context "when state is running" do
      it "returns 'running'" do
        expect(inference_endpoint.display_state).to eq("running")
      end
    end

    context "when state is wait_replicas" do
      before { strand.update(label: "wait_replicas") }

      it "returns 'creating'" do
        expect(inference_endpoint.display_state).to eq("creating")
      end

      it "returns 'deleting' when destroy semaphore is set" do
        inference_endpoint.incr_destroy
        expect(inference_endpoint.display_state).to eq("deleting")
      end

      it "returns 'deleting' when destroying semaphore is set" do
        inference_endpoint.incr_destroying
        expect(inference_endpoint.display_state).to eq("deleting")
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

    before do
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=).with(true)
      allow(http).to receive(:read_timeout=).with(30)
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
