# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "inference-endpoint" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  describe "feature enabled" do
    before do
      project.set_ff_inference_ui(true)
      project_wo_permissions.set_ff_inference_ui(true)
      login(user.email)
    end

    it "can handle empty list of inference endpoints" do
      visit "#{project.path}/inference-endpoint"

      expect(page.title).to eq("Ubicloud - Inference Endpoints")
    end

    it "shows the right inference endpoints" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
      lb = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-1", src_port: 80, dst_port: 80, health_check_endpoint: "/up")
      InferenceEndpoint.create_with_id(name: "ie1", model_name: "e5-mistral-7b-it", project_id: project_wo_permissions.id, is_public: true, visible: true, location: "loc", vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id)
      InferenceEndpoint.create_with_id(name: "ie2", model_name: "e5-mistral-8b-it", project_id: project_wo_permissions.id, is_public: true, visible: false, location: "loc", vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id)
      InferenceEndpoint.create_with_id(name: "ie3", model_name: "llama-guard-3-8b", project_id: project_wo_permissions.id, is_public: false, visible: true, location: "loc", vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id)
      ie = InferenceEndpoint.create_with_id(name: "ie4", model_name: "llama-3-1-405b-it", project_id: project.id, is_public: false, visible: true, location: "loc", vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id)
      ie.associate_with_project(project)
      InferenceEndpoint.create_with_id(name: "ie5", model_name: "test-model", project_id: project.id, is_public: false, visible: true, location: "loc", vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id)
      visit "#{project.path}/inference-endpoint"

      expect(page.title).to eq("Ubicloud - Inference Endpoints")
      expect(page).to have_content("e5-mistral-7b-it")
      expect(page).to have_no_content("e5-mistral-8b-it") # not visible
      expect(page).to have_no_content("llama-guard-3-8b") # private model of another project
      expect(page).to have_content("llama-3-1-405b-it")
      expect(page).to have_no_content("test-model") # no permissions
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

  describe "feature disabled" do
    before do
      project.set_ff_inference_ui(false)
      login(user.email)
      visit "#{project.path}/inference-endpoint"
    end

    it "inference endpoint page is not accessible" do
      expect(page.status_code).to eq(404)
    end
  end

  describe "unauthenticated" do
    it "inference endpoint page is not accessible" do
      visit "/inference-endpoint"

      expect(page.title).to eq("Ubicloud - Login")
    end
  end
end
