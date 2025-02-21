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
      lb = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-1", src_port: 80, dst_port: 80, health_check_endpoint: "/up", project_id: project.id)
      [
        ["ie1", "e5-mistral-7b-it", project_wo_permissions, true, true, {capability: "Embeddings", hf_model: "foo/bar"}],
        ["ie2", "e5-mistral-8b-it", project_wo_permissions, true, false, {capability: "Embeddings"}],
        ["ie3", "llama-guard-3-8b", project_wo_permissions, false, true, {capability: "Text Generation"}],
        ["ie4", "mistral-small-3", project, false, true, {capability: "Text Generation"}],
        ["ie5", "llama-3-2-3b-it", project, false, true, {capability: "Text Generation"}],
        ["ie6", "test-model", project_wo_permissions, false, true, {capability: "Text Generation"}],
        ["ie7", "unknown-capability", project_wo_permissions, true, true, {capability: "wrong capability"}]
      ].each do |name, model_name, project, is_public, visible, tags|
        InferenceEndpoint.create_with_id(name:, model_name:, project_id: project.id, is_public:, visible:, load_balancer_id: lb.id, location: "loc", vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, tags:)
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

    it "does not show inference endpoints without permissions" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
      lb = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-1", src_port: 80, dst_port: 80, health_check_endpoint: "/up", project_id: project.id)
      InferenceEndpoint.create_with_id(name: "ie1", model_name: "test-model", project_id: project_wo_permissions.id, is_public: true, visible: true, location: "loc", vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id)
      visit "#{project_wo_permissions.path}/inference-endpoint"

      expect(page.title).to eq("Ubicloud - Inference Endpoints")
      expect(page).to have_no_content("e5-mistral-7b-it")
    end

    it "shows free quota notice with correct free inference tokens" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").subject
      lb = LoadBalancer.create_with_id(private_subnet_id: ps.id, name: "dummy-lb-1", src_port: 80, dst_port: 80, health_check_endpoint: "/up", project_id: project.id)
      ie = InferenceEndpoint.create_with_id(name: "ie1", model_name: "test-model", project_id: project.id, is_public: true, visible: true, location: "loc", vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id)
      visit "#{project.path}/inference-api-key"
      expect(page.text).to include("You have 500000 free inference tokens available (few-minute delay). Free quota refreshes next month.")

      BillingRecord.create_with_id(
        project_id: project.id,
        resource_id: ie.id,
        resource_name: ie.name,
        span: Sequel::Postgres::PGRange.new(Time.now, nil),
        billing_rate_id: BillingRate.from_resource_type("InferenceTokens").first["id"],
        amount: 100000
      )
      visit "#{project.path}/inference-api-key"
      expect(page.text).to include("You have 400000 free inference tokens available (few-minute delay). Free quota refreshes next month.")

      BillingRecord.create_with_id(
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
