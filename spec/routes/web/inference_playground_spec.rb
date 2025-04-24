# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "inference-playground" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  describe "feature enabled" do
    before do
      login(user.email)
    end

    it "can handle empty list of inference endpoints" do
      visit "#{project.path}/inference-playground"

      expect(page.title).to eq("Ubicloud - Playground")
    end

    it "gives choice of inference endpoints" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
      lb = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-1", health_check_endpoint: "/up", project_id: project.id)
      LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 80, dst_port: 80)
      lb2 = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-2", health_check_endpoint: "/up", project_id: project.id)
      LoadBalancerPort.create(load_balancer_id: lb2.id, src_port: 80, dst_port: 80)
      [
        ["ie1", "e5-mistral-7b-it", project_wo_permissions, true, true, lb.id, {capability: "Embeddings"}],
        ["ie2", "e5-mistral-8b-it", project_wo_permissions, true, false, lb.id, {capability: "Text Generation"}],
        ["ie3", "llama-guard-3-8b", project_wo_permissions, false, true, lb.id, {capability: "Text Generation"}],
        ["ie4", "mistral-small-3", project, false, true, lb2.id, {capability: "Text Generation"}],
        ["ie5", "llama-3-2-3b-it", project, false, false, lb.id, {capability: "Text Generation"}],
        ["ie6", "test-model", project_wo_permissions, true, true, lb.id, {capability: "Text Generation"}]
      ].each do |name, model_name, project, is_public, visible, load_balancer_id, tags|
        InferenceEndpoint.create_with_id(name:, model_name:, project_id: project.id, is_public:, visible:, load_balancer_id:, location_id: Location::HETZNER_FSN1_ID, vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, tags:)
      end
      inference_router = InferenceRouter.create(
        name: "ir-name",
        location_id: Location::HETZNER_FSN1_ID,
        vm_size: "standard-2",
        replica_count: 1,
        project_id: project.id,
        load_balancer_id: lb.id,
        private_subnet_id: ps.id
      )
      [
        ["meta-llama/Llama-3.2-1B-Instruct", "llama-3-2-1b-it-input", "llama-3-2-1b-it-output", true, {capability: "Text Generation", hf_model: "foo/bar"}],
        ["Invisible Model", "test-model-input", "test-model-output", false, {capability: "Text Generation"}],
        ["Embedding Model", "test-model2-input", "test-model2-output", true, {capability: "Embeddings"}]
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
      visit "#{project.path}/inference-playground"

      expect(page.title).to eq("Ubicloud - Playground")
      expect(page).to have_no_content("e5-mistral-7b-it")
      expect(page).to have_no_content("e5-mistral-8b-it")
      expect(page).to have_no_content("llama-guard-3-8b")
      expect(page).to have_no_content("llama-3-2-3b-it")
      expect(page).to have_select("inference_endpoint", selected: "mistral-small-3", with_options: ["mistral-small-3", "test-model", "meta-llama/Llama-3.2-1B-Instruct"])
    end

    it "gives choice of inference api keys" do
      visit "#{project.path}/inference-api-key"
      expect(ApiKey.all).to be_empty
      click_button "Create API Key"

      visit "#{project.path}/inference-playground"

      expect(page.title).to eq("Ubicloud - Playground")
      expect(page).to have_select("inference_api_key", selected: ApiKey.first.ubid)
    end
  end

  describe "unauthenticated" do
    it "inference endpoint page is not accessible" do
      visit "/inference-playground"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end
end
