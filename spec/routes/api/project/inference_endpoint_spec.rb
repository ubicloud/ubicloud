# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "inference endpoint" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  let(:ps) { Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject }

  let(:lb) do
    lb = LoadBalancer.create(private_subnet_id: ps.id, name: "dummy-lb-1", health_check_endpoint: "/up", project_id: project.id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 80, dst_port: 8000)
    lb
  end

  let(:ie) do
    InferenceEndpoint.create(
      name: "test-model", model_name: "test-model", project_id: project.id,
      is_public: true, visible: true, load_balancer_id: lb.id,
      location_id: Location::HETZNER_FSN1_ID, vm_size: "size",
      replica_count: 1, boot_image: "image", storage_volumes: [],
      engine_params: "", engine: "vllm", private_subnet_id: ps.id,
      tags: {"capability" => "Text Generation", "display_name" => "Test Model", "hf_model" => "test-org/test-model"}
    )
  end

  let(:ir) do
    InferenceRouter.create(
      name: "ir-name", location_id: Location::HETZNER_FSN1_ID, vm_size: "standard-2",
      replica_count: 1, project_id: project.id, load_balancer_id: lb.id, private_subnet_id: ps.id
    )
  end

  let(:irm) do
    InferenceRouterModel.create(
      model_name: "test-org/test-model2",
      prompt_billing_resource: "test-model2-input",
      completion_billing_resource: "test-model2-output",
      project_inflight_limit: 100, project_prompt_tps_limit: 10_000,
      project_completion_tps_limit: 10_000, visible: true,
      tags: {"capability" => "Text Generation", "hf_model" => "test-org/test-model2", "multimodal" => true, "context_length" => "128k"}
    )
  end

  let(:irt) do
    InferenceRouterTarget.create(
      name: "test-target", host: "test-host", api_key: "test-key",
      inflight_limit: 10, priority: 1,
      inference_router_model_id: irm.id, inference_router_id: ir.id, enabled: true
    )
  end

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    it "success list empty inference endpoints" do
      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"]).to eq([])
    end

    it "lists both inference endpoints and inference router models" do
      ie
      irt

      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)

      expect(body["items"]).to eq([
        {
          "id" => ie.ubid,
          "name" => "test-model",
          "display_name" => "Test Model",
          "url" => lb.health_check_url,
          "model_name" => "test-model",
          "tags" => {
            "capability" => "Text Generation",
            "hf_model" => "test-org/test-model"
          },
          "price" => {
            "per_million_prompt_tokens" => 0.05,
            "per_million_completion_tokens" => 0.05
          }
        },
        {
          "id" => irm.ubid,
          "name" => "test-org/test-model2",
          "display_name" => "test-org/test-model2",
          "url" => lb.health_check_url,
          "model_name" => "test-org/test-model2",
          "tags" => {
            "capability" => "Text Generation",
            "hf_model" => "test-org/test-model2",
            "multimodal" => true,
            "context_length" => "128k"
          },
          "price" => {
            "per_million_prompt_tokens" => 0.2,
            "per_million_completion_tokens" => 0.7
          }
        }
      ])
    end

    it "returns null prices when billing rate does not exist" do
      ie.update(model_name: "no-billing-rate-model")

      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      item = body["items"].first
      expect(item["price"]).to eq({
        "per_million_prompt_tokens" => nil,
        "per_million_completion_tokens" => nil
      })
    end

    it "does not include irrelevant tags in the response" do
      irt

      ie.update(tags: ie.tags.merge("visible_projects" => [project.id], "internal_key" => "secret"))
      irm.update(tags: irm.tags.merge("visible_projects" => [project.id], "some_internal" => "value"))

      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      allowed_keys = %w[hf_model capability multimodal display_name context_length]
      body["items"].each do |item|
        expect(item["tags"].keys - allowed_keys).to eq([])
      end
    end

    it "does not list invisible or unauthorized inference endpoints" do
      # Invisible IE
      ie.update(visible: false)

      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"]).to eq([])

      # Private IE without permissions
      ie.update(visible: true, is_public: false, project_id: project_wo_permissions.id)

      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"]).to eq([])

      # Private IE with permissions
      ie.update(visible: true, is_public: false, project_id: project.id)

      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].length).to eq(1)

      # Public IE
      ie.update(visible: true, is_public: true)

      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].length).to eq(1)
    end

    it "does not list invisible inference router models" do
      # Invisible IRM
      irt
      irm.update(visible: false)

      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"]).to eq([])

      # Invisible IRM but project in visible_projects
      irm.update(visible: false, tags: irm.tags.merge("visible_projects" => [project.id]))

      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].length).to eq(1)

      # Invisible IRM with different project in visible_projects
      irm.update(visible: false, tags: irm.tags.merge("visible_projects" => [project_wo_permissions.id]))

      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"]).to eq([])

      # Visible IRM
      irm.update(visible: true, tags: irm.tags.except("visible_projects"))

      get "/project/#{project.ubid}/inference-endpoint"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].length).to eq(1)
    end
  end
end
