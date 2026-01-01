# frozen_string_literal: true

require "spec_helper"
require_relative "../../../prog/ai/inference_router_target_nexus"

RSpec.describe Prog::Ai::InferenceRouterTargetNexus do
  subject(:nexus) { described_class.new(target_strand) }

  let(:project) { Project.create(name: "default") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:inference_router) do
    Prog::Ai::InferenceRouterNexus.assemble(
      project_id: project.id,
      location_id:
    )
  end

  let(:inference_router_model) do
    InferenceRouterModel.create(
      model_name: "meta-llama/Llama-3.2-1B-Instruct",
      prompt_billing_resource: "llama-3-2-1b-it-input",
      completion_billing_resource: "llama-3-2-1b-it-output",
      project_inflight_limit: 100,
      project_prompt_tps_limit: 10_000,
      project_completion_tps_limit: 10_000,
      visible: true,
      tags: {capability: "Text Generation"}
    )
  end

  let(:config) do
    {
      gpuCount: 1,
      gpuTypeIds: ["NVIDIA RTX 4000 Ada"],
      dataCenterIds: ["EU-RO-1"],
      env: {VLLM_PARAMS: "--tensor-parallel-size 1 --gpu-memory-utilization 0.95"}
    }
  end

  let(:target_strand) do
    described_class.assemble(
      inference_router_id: inference_router.id,
      inference_router_model_id: inference_router_model.id,
      name: "target",
      priority: 1,
      type: "runpod",
      config:,
      inflight_limit: 10
    )
  end

  before do
    Firewall.create(
      name: "inference-router-firewall",
      project_id: project.id,
      location_id:,
      description: "inference-router-firewall"
    )

    allow(Config).to receive(:inference_endpoint_service_project_id)
      .and_return(project.id)
  end

  describe ".assemble" do
    it "creates an InferenceRouterTarget with expected attributes" do
      strand = described_class.assemble(
        inference_router_id: inference_router.id,
        inference_router_model_id: inference_router_model.id,
        name: "target",
        priority: 1,
        inflight_limit: 10
      )

      target = strand.subject
      expect(target.inference_router_model_id).to eq(inference_router_model.id)
      expect(target.inference_router_id).to eq(inference_router.id)
    end
  end

  describe "#before_run" do
    context "when destroy is set" do
      before { nexus.incr_destroy }

      it "hops to destroy if not already destroying" do
        nexus.strand.update(label: "active")
        expect { nexus.before_run }.to hop("destroy")
      end

      it "does not hop if already in destroy state" do
        nexus.strand.update(label: "destroy")
        expect { nexus.before_run }.not_to hop("destroy")
      end

      it "pops stack and hops to back-link if there are operations on the stack" do
        original_stack = nexus.strand.stack.dup
        new_frame = {"subject_id" => nexus.inference_router_target.id, "link" => [nexus.strand.prog, "destroy"]}
        new_stack = [new_frame] + original_stack
        nexus.strand.update(label: "destroy", stack: new_stack)
        reloaded_nexus = described_class.new(nexus.strand.reload)
        reloaded_nexus.incr_destroy
        expect { reloaded_nexus.before_run }.to hop("destroy")
      end
    end
  end

  describe "#start" do
    it "hops to wait for manual target" do
      target_strand.subject.update(type: "manual")
      expect { nexus.start }.to hop("wait")
    end

    it "hops to setup for runpod target" do
      expect { nexus.start }.to hop("setup")
    end
  end

  describe "#setup" do
    it "creates a pod and updates target state" do
      stub_request(:get, "https://rest.runpod.io/v1/pods")
        .with(query: {name: target_strand.subject.ubid})
        .to_return(status: 200, body: "[]")
      stub_request(:post, "https://rest.runpod.io/v1/pods")
        .to_return(status: 201, body: {id: "pod-123"}.to_json)

      expect { nexus.setup }.to hop("wait_setup")
      expect(Strand[target_strand.id].subject).to have_attributes(state: {"pod_id" => "pod-123"})
    end
  end

  describe "#wait_setup" do
    before do
      nexus.inference_router_target.update(state: {"pod_id" => "pod-123"})
    end

    it "naps if pod publicIp is empty" do
      stub_request(:get, "https://rest.runpod.io/v1/pods/pod-123")
        .to_return(status: 200, body: {publicIp: ""}.to_json)

      expect { nexus.wait_setup }.to nap(10)
    end

    it "hops to wait if publicIp is available" do
      stub_request(:get, "https://rest.runpod.io/v1/pods/pod-123")
        .to_return(status: 200, body: {publicIp: "1.1.1.1"}.to_json)

      expect { nexus.wait_setup }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps for a long time (30 days)" do
      expect { nexus.wait }.to nap(60 * 60 * 24 * 30)
    end
  end

  describe "#destroy" do
    it "destroys target and deletes pod if pod_id is set" do
      target_strand.subject.update(state: {"pod_id" => "pod-123"})
      stub_request(:delete, "https://rest.runpod.io/v1/pods/pod-123")
        .to_return(status: 200)

      expect { nexus.destroy }.to exit({"msg" => "inference router target is deleted"})
    end

    it "destroys target without deleting pod if none exists" do
      expect { nexus.destroy }.to exit({"msg" => "inference router target is deleted"})
    end
  end
end
