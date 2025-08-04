# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "inference-endpoint" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  describe "feature enabled" do
    before do
      login(user.email)
    end

    it "can handle empty list of inference endpoints" do
      visit "#{project.path}/inference-endpoint"

      expect(page.title).to eq("Ubicloud - Inference Endpoints")
    end

    it "shows the right inference endpoints" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
      lb = LoadBalancer.create(private_subnet_id: ps.id, name: "dummy-lb-1", health_check_endpoint: "/up", project_id: project.id)
      LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 80, dst_port: 8000)
      [
        ["ie1", "e5-mistral-7b-it", project_wo_permissions, true, true, {capability: "Embeddings", hf_model: "foo/bar"}],
        ["ie2", "e5-mistral-8b-it", project_wo_permissions, true, false, {capability: "Embeddings"}],
        ["ie3", "llama-guard-3-8b", project_wo_permissions, false, true, {capability: "Text Generation"}],
        ["ie4", "mistral-small-3", project, false, true, {capability: "Text Generation"}],
        ["ie5", "llama-3-3-70b-turbo", project, false, true, {capability: "Text Generation"}],
        ["ie6", "test-model", project_wo_permissions, false, true, {capability: "Text Generation"}],
        ["ie7", "unknown-capability", project_wo_permissions, true, true, {capability: "wrong capability"}]
      ].each do |name, model_name, project, is_public, visible, tags|
        InferenceEndpoint.create(name:, model_name:, project_id: project.id, is_public:, visible:, load_balancer_id: lb.id, location_id: Location::HETZNER_FSN1_ID, vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, tags:)
      end

      visit "#{project.path}/inference-endpoint"

      expect(page.title).to eq("Ubicloud - Inference Endpoints")
      expect(page).to have_content("e5-mistral-7b-it")
      expect(page.all("a").any? { |a| a["href"] == "https://huggingface.co/foo/bar" }).to be true
      expect(page).to have_no_content("e5-mistral-8b-it") # not visible
      expect(page).to have_no_content("llama-guard-3-8b") # private model of another project
      expect(page).to have_content("mistral-small-3")
      expect(page).to have_no_content("test-model") # no permissions
      expect(page).to have_no_content("unknown-capability")
    end

    it "shows the right inference router models" do
      private_subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
      load_balancer = LoadBalancer.create(
        private_subnet_id: private_subnet.id, name: "dummy-lb-1", health_check_endpoint: "/up", project_id: project.id
      )
      LoadBalancerPort.create(load_balancer_id: load_balancer.id, src_port: 80, dst_port: 8000)
      inference_router = InferenceRouter.create(
        name: "ir-name", location_id: Location::HETZNER_FSN1_ID, vm_size: "standard-2", replica_count: 1,
        project_id: project.id, load_balancer_id: load_balancer.id, private_subnet_id: private_subnet.id
      )
      [
        ["meta-llama/Llama-3.2-1B-Instruct", "llama-3-2-1b-it-input", "llama-3-2-1b-it-output", true, {capability: "Text Generation", hf_model: "foo/bar"}],
        ["Invisible Model", "test-model-input", "test-model-output", false, {capability: "Text Generation"}],
        ["Unknown Capability", "test-model2-input", "test-model2-output", true, {capability: "Unknown"}]
      ].each do |model_name, prompt_billing, completion_billing, visible, tags|
        model = InferenceRouterModel.create(
          model_name:, prompt_billing_resource: prompt_billing, completion_billing_resource: completion_billing,
          project_inflight_limit: 100, project_prompt_tps_limit: 10_000, project_completion_tps_limit: 10_000,
          visible:, tags:
        )
        InferenceRouterTarget.create(
          name: "test-target", host: "test-host", api_key: "test-key", inflight_limit: 10, priority: 1,
          inference_router_model_id: model.id, inference_router_id: inference_router.id, enabled: true
        )
      end
      InferenceRouterModel.create(
        model_name: "Model without Target", prompt_billing_resource: "test-model2-input", completion_billing_resource: "test-model2-output",
        project_inflight_limit: 100, project_prompt_tps_limit: 10_000, project_completion_tps_limit: 10_000,
        visible: true, tags: {capability: "Text Generation"}
      )

      expect(BillingRate).to receive(:from_resource_properties)
        .with("InferenceTokens", "llama-3-2-1b-it-input", "global")
        .and_return({"unit_price" => 0.0000001})
      expect(BillingRate).to receive(:from_resource_properties)
        .with("InferenceTokens", "llama-3-2-1b-it-output", "global")
        .and_return({"unit_price" => 0.0000002})
      visit "#{project.path}/inference-endpoint"

      expect(page.title).to eq("Ubicloud - Inference Endpoints")
      expect(page).to have_content("meta-llama/Llama-3.2-1B-Instruct")
      expect(page).to have_link(href: "https://huggingface.co/foo/bar")
      expect(page).to have_content("Input: $0.10 / 1M tokens")
      expect(page).to have_content("Output: $0.20 / 1M tokens")
      expect(page).to have_no_content("Invisible Model")
      expect(page).to have_no_content("Unknown Capability")
      expect(page).to have_no_content("Model without Target")
    end

    it "shows both inference endpoints and router models when both are present" do
      private_subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
      load_balancer = LoadBalancer.create(private_subnet_id: private_subnet.id, name: "dummy-lb-1", health_check_endpoint: "/up", project_id: project.id)
      LoadBalancerPort.create(load_balancer_id: load_balancer.id, src_port: 80, dst_port: 8000)
      InferenceEndpoint.create(
        name: "mistral-small-3",
        model_name: "mistral-small-3",
        project_id: project.id,
        is_public: true,
        visible: true,
        load_balancer_id: load_balancer.id,
        location_id: Location::HETZNER_FSN1_ID,
        vm_size: "size",
        replica_count: 1,
        boot_image: "image",
        storage_volumes: [],
        engine_params: "",
        engine: "vllm",
        private_subnet_id: private_subnet.id,
        tags: {capability: "Text Generation"}
      )
      inference_router = InferenceRouter.create(
        name: "ir-name",
        location_id: Location::HETZNER_FSN1_ID,
        vm_size: "standard-2",
        replica_count: 1,
        project_id: project.id,
        load_balancer_id: load_balancer.id,
        private_subnet_id: private_subnet.id
      )
      inference_router_model = InferenceRouterModel.create(
        model_name: "meta-llama/Llama-3.2-1B-Instruct",
        prompt_billing_resource: "llama-3-2-1b-it-input",
        completion_billing_resource: "llama-3-2-1b-it-output",
        project_inflight_limit: 100,
        project_prompt_tps_limit: 1000,
        project_completion_tps_limit: 1000,
        visible: true,
        tags: {capability: "Text Generation"}
      )
      InferenceRouterTarget.create(
        name: "test-target",
        host: "test-host",
        api_key: "test-key",
        inflight_limit: 10,
        priority: 1,
        inference_router_model_id: inference_router_model.id,
        inference_router_id: inference_router.id,
        enabled: true
      )
      visit "#{project.path}/inference-endpoint"
      expect(page.title).to eq("Ubicloud - Inference Endpoints")
      expect(page).to have_content("mistral-small-3")
      expect(page).to have_content("meta-llama/Llama-3.2-1B-Instruct")
    end

    it "does not show inference endpoints without permissions" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
      lb = LoadBalancer.create(private_subnet_id: ps.id, name: "dummy-lb-1", health_check_endpoint: "/up", project_id: project.id)
      LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 80, dst_port: 80)
      InferenceEndpoint.create(name: "ie1", model_name: "test-model", project_id: project_wo_permissions.id, is_public: true, visible: true, location_id: Location::HETZNER_FSN1_ID, vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id)
      visit "#{project_wo_permissions.path}/inference-endpoint"

      expect(page.title).to eq("Ubicloud - Inference Endpoints")
      expect(page).to have_no_content("e5-mistral-7b-it")
    end

    it "shows free quota notice with correct free inference tokens" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
      lb = LoadBalancer.create(private_subnet_id: ps.id, name: "dummy-lb-1", health_check_endpoint: "/up", project_id: project.id)
      LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 80, dst_port: 80)
      ie = InferenceEndpoint.create(name: "ie1", model_name: "test-model", project_id: project.id, is_public: true, visible: true, location_id: Location::HETZNER_FSN1_ID, vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id)
      visit "#{project.path}/inference-api-key"
      expect(page.text).to include("You have 500000 free inference tokens available (few-minute delay). Free quota refreshes next month.")

      BillingRecord.create(
        project_id: project.id,
        resource_id: ie.id,
        resource_name: ie.name,
        span: Sequel::Postgres::PGRange.new(Time.now, nil),
        billing_rate_id: BillingRate.from_resource_type("InferenceTokens").first["id"],
        amount: 100000
      )
      visit "#{project.path}/inference-api-key"
      expect(page.text).to include("You have 400000 free inference tokens available (few-minute delay). Free quota refreshes next month.")

      BillingRecord.create(
        project_id: project.id,
        resource_id: ie.id,
        resource_name: ie.name,
        span: Sequel::Postgres::PGRange.new(Time.now, nil),
        billing_rate_id: BillingRate.from_resource_type("InferenceTokens").first["id"],
        amount: 99999999
      )
      visit "#{project.path}/inference-api-key"
      expect(page.text).to include("You have 0 free inference tokens available (few-minute delay). Free quota refreshes next month.")
    end

    it "shows free quota notice with billing valid message" do
      expect(Config).to receive(:stripe_secret_key).at_least(:once).and_return(nil)
      expect(project.has_valid_payment_method?).to be true
      visit "#{project.path}/inference-api-key"
      expect(page.text).to include("Billing information is valid. Charges start after the free quota.")
    end

    it "shows free quota notice with billing unavailable message" do
      expect(Config).to receive(:stripe_secret_key).at_least(:once).and_return("test_stripe_secret_key")
      expect(project.has_valid_payment_method?).to be false
      visit "#{project.path}/inference-api-key"
      expect(page.text).to include("To avoid service interruption, please click here to add a valid billing method.")
    end
  end

  describe "unauthenticated" do
    it "inference endpoint page is not accessible" do
      visit "/inference-endpoint"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end
end
