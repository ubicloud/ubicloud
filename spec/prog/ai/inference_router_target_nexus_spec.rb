# frozen_string_literal: true

require "spec_helper"
require_relative "../../../prog/ai/inference_router_target_nexus"

RSpec.describe Prog::Ai::InferenceRouterTargetNexus do
  subject(:nexus) { described_class.new(target_strand) }

  let(:project) { Project.create_with_id(name: "default") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:inference_router) do
    Prog::Ai::InferenceRouterNexus.assemble(
      project_id: project.id,
      location_id: location_id
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
      config: config,
      inflight_limit: 10
    )
  end

  before do
    Firewall.create_with_id(
      name: "inference-router-firewall",
      project_id: project.id,
      location_id: location_id,
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

      target = InferenceRouterTarget[strand.id]
      expect(target.inference_router_model_id).to eq(inference_router_model.id)
      expect(target.inference_router_id).to eq(inference_router.id)
    end
  end

  describe "#before_run" do
    context "when destroy is set" do
      before do
        expect(nexus).to receive(:when_destroy_set?).and_yield
      end

      it "hops to destroy if not already destroying" do
        expect(nexus.strand).to receive(:label).twice.and_return("active")
        expect { nexus.before_run }.to hop("destroy")
      end

      it "does not hop if already in destroy state" do
        expect(nexus.strand).to receive(:label).and_return("destroy")
        expect { nexus.before_run }.not_to hop("destroy")
      end

      it "exits if there are operations on the stack" do
        expect(nexus.strand).to receive(:label).and_return("destroy")
        expect(nexus.strand.stack).to receive(:count).and_return(2)
        expect { nexus.before_run }.to exit(
          {"msg" => "operation is cancelled due to the destruction of the inference router target"}
        )
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
    let(:client) { instance_double(RunpodClient) }

    it "creates a pod and updates target state" do
      expect(RunpodClient).to receive(:new).and_return(client)
      expect(client).to receive(:create_pod).with(
        target_strand.subject.ubid,
        hash_including("env" => hash_including(
          "HF_MODEL" => inference_router_model.model_name,
          "VLLM_PARAMS" => config[:env][:VLLM_PARAMS]
        ))
      ).and_return("pod-123")
      expect { nexus.setup }.to hop("wait_setup")
      expect(target_strand.subject).to have_attributes(state: {"pod_id" => "pod-123"})
    end
  end

  describe "#wait_setup" do
    let(:client) { instance_double(RunpodClient) }

    before do
      expect(RunpodClient).to receive(:new).and_return(client)
    end

    it "naps if pod publicIp is empty" do
      expect(client).to receive(:get_pod).and_return({"publicIp" => ""})
      expect { nexus.wait_setup }.to nap(10)
    end

    it "hops to wait if publicIp is available" do
      expect(client).to receive(:get_pod).and_return({"publicIp" => "1.1.1.1"})
      expect { nexus.wait_setup }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps for a long time (30 days)" do
      expect { nexus.wait }.to nap(60 * 60 * 24 * 30)
    end
  end

  describe "#destroy" do
    let(:client) { instance_double(RunpodClient) }

    it "destroys target and deletes pod if pod_id is set" do
      expect(RunpodClient).to receive(:new).and_return(client)
      target_strand.subject.update(state: {"pod_id" => "pod-123"})
      expect(client).to receive(:delete_pod).with("pod-123")
      expect { nexus.destroy }.to exit({"msg" => "inference router target is deleted"})
    end

    it "destroys target without deleting pod if none exists" do
      expect { nexus.destroy }.to exit({"msg" => "inference router target is deleted"})
    end
  end
end
