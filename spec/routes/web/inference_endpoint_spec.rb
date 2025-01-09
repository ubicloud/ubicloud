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
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
      lb = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-1", src_port: 80, dst_port: 80, health_check_endpoint: "/up")
      [
        ["ie1", "e5-mistral-7b-it", project_wo_permissions, true, true, {capability: "Embeddings", hf_model: "foo/bar"}],
        ["ie2", "e5-mistral-8b-it", project_wo_permissions, true, false, {capability: "Embeddings"}],
        ["ie3", "llama-guard-3-8b", project_wo_permissions, false, true, {capability: "Text Generation"}],
        ["ie4", "llama-3-1-405b-it", project, false, true, {capability: "Text Generation"}],
        ["ie5", "llama-3-2-3b-it", project, false, true, {capability: "Text Generation"}],
        ["ie6", "test-model", project_wo_permissions, false, true, {capability: "Text Generation"}],
        ["ie7", "unknown-capability", project_wo_permissions, true, true, {capability: "wrong capability"}]
      ].each do |name, model_name, project, is_public, visible, tags|
        ie = InferenceEndpoint.create_with_id(name:, model_name:, project_id: project.id, is_public:, visible:, load_balancer_id: lb.id, location: "loc", vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, tags:)
        ie.associate_with_project(project)
      end

      visit "#{project.path}/inference-endpoint"

      expect(page.title).to eq("Ubicloud - Inference Endpoints")
      expect(page).to have_content("e5-mistral-7b-it")
      expect(page.all("a").any? { |a| a["href"] == "https://huggingface.co/foo/bar" }).to be true
      expect(page).to have_no_content("e5-mistral-8b-it") # not visible
      expect(page).to have_no_content("llama-guard-3-8b") # private model of another project
      expect(page).to have_content("llama-3-1-405b-it")
      expect(page).to have_no_content("test-model") # no permissions
      expect(page).to have_no_content("unknown-capability")
    end

    it "does not show inference endpoints without permissions" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
      lb = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-1", src_port: 80, dst_port: 80, health_check_endpoint: "/up")
      ie = InferenceEndpoint.create_with_id(name: "ie1", model_name: "test-model", project_id: project_wo_permissions.id, is_public: true, visible: true, location: "loc", vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id)
      ie.associate_with_project(project_wo_permissions)
      visit "#{project_wo_permissions.path}/inference-endpoint"

      expect(page.title).to eq("Ubicloud - Inference Endpoints")
      expect(page).to have_no_content("e5-mistral-7b-it")
    end
  end

  describe "unauthenticated" do
    it "inference endpoint page is not accessible" do
      visit "/inference-endpoint"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end
end
