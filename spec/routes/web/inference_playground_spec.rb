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
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
      lb = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-1", src_port: 80, dst_port: 80, health_check_endpoint: "/up")
      lb2 = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-2", src_port: 80, dst_port: 80, health_check_endpoint: "/up")
      [
        ["ie1", "e5-mistral-7b-it", project_wo_permissions, true, true, lb.id, {capability: "Embeddings"}],
        ["ie2", "e5-mistral-8b-it", project_wo_permissions, true, false, lb.id, {capability: "Text Generation"}],
        ["ie3", "llama-guard-3-8b", project_wo_permissions, false, true, lb.id, {capability: "Text Generation"}],
        ["ie4", "llama-3-1-405b-it", project, false, true, lb2.id, {capability: "Text Generation"}],
        ["ie5", "llama-3-2-3b-it", project, false, false, lb.id, {capability: "Text Generation"}],
        ["ie6", "test-model", project_wo_permissions, true, true, lb.id, {capability: "Text Generation"}]
      ].each do |name, model_name, project, is_public, visible, load_balancer_id, tags|
        ie = InferenceEndpoint.create_with_id(name:, model_name:, project_id: project.id, is_public:, visible:, load_balancer_id:, location: "loc", vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, tags:)
        ie.associate_with_project(project)
      end
      visit "#{project.path}/inference-playground"

      expect(page.title).to eq("Ubicloud - Playground")
      expect(page).to have_no_content("e5-mistral-7b-it")
      expect(page).to have_no_content("e5-mistral-8b-it")
      expect(page).to have_no_content("llama-guard-3-8b")
      expect(page).to have_no_content("llama-3-2-3b-it")
      expect(page).to have_select("inference_endpoint", selected: "llama-3-1-405b-it", with_options: ["llama-3-1-405b-it", "test-model"])
    end

    it "gives choice of inference tokens" do
      visit "#{project.path}/inference-token"
      expect(ApiKey.all).to be_empty
      click_button "Create Token"

      visit "#{project.path}/inference-playground"

      expect(page.title).to eq("Ubicloud - Playground")
      expect(page).to have_select("inference_token", selected: ApiKey.first.ubid)
    end
  end

  describe "unauthenticated" do
    it "inference endpoint page is not accessible" do
      visit "/inference-playground"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end
end
