# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Ai::InferenceRouterNexus do
  subject(:nx) { described_class.new(Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77")) }

  let(:inference_router) {
    instance_double(InferenceRouter, id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77", replica_count: 2)
  }
  let(:replicas) { Array.new(2) { instance_double(InferenceRouterReplica, strand: instance_double(Strand, label: "wait")) } }

  before do
    allow(nx).to receive_messages(inference_router: inference_router, replicas: replicas)
    allow(inference_router).to receive(:replicas).and_return(replicas)
  end

  describe ".assemble" do
    let(:customer_project) { Project.create_with_id(name: "default") }
    let(:ie_project) { Project.create_with_id(name: "default") }

    it "validates input" do
      expect(Config).to receive(:inference_endpoint_service_project_id).and_return(ie_project.id).at_least(:once)
      Firewall.create_with_id(name: "inference-router-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: ie_project.id)
      DnsZone.create_with_id(name: "ai.ubicloud.com", project_id: ie_project.id)

      expect {
        described_class.assemble(project_id: "ed6afccf-7025-4f35-8241-454221d75e18", location_id: Location::HETZNER_FSN1_ID, name: "test-router", replica_count: 1)
      }.to raise_error("No existing project")

      expect {
        described_class.assemble(project_id: customer_project.id, location_id: nil, name: "test-router", replica_count: 1)
      }.to raise_error RuntimeError, "No existing location"

      expect {
        described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "test-router", replica_count: "abc")
      }.to raise_error("Invalid replica count")

      expect {
        described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "test-router", replica_count: 0)
      }.to raise_error("Invalid replica count")

      expect {
        described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "test-router", replica_count: 10)
      }.to raise_error("Invalid replica count")

      expect {
        described_class.assemble(project_id: customer_project.id, location_id: Location[name: "leaseweb-wdc02"].id, name: "test-router", replica_count: 1)
      }.to raise_error("No firewall named 'inference-router-firewall' configured for inference routers in leaseweb-wdc02")

      expect {
        st = described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "test-router-public", replica_count: 1)
        expect(st.subject.load_balancer.hostname).to eq("test-router-public.ai.ubicloud.com")
        expect(st.subject.load_balancer.stack).to eq("dual")
      }.not_to raise_error

      Firewall.dataset.destroy
      InferenceRouterReplica.dataset.destroy
      InferenceRouter.dataset.destroy
      LoadBalancer.dataset.destroy
      Nic.dataset.destroy
      PrivateSubnet.dataset.destroy
      Vm.dataset.destroy
      expect {
        ie_project.destroy
        described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "test-router", replica_count: 1)
      }.to raise_error("No project configured for inference routers")
    end

    it "works without dns zone" do
      expect(Config).to receive(:inference_endpoint_service_project_id).and_return(ie_project.id).at_least(:once)
      Firewall.create_with_id(name: "inference-router-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: ie_project.id)
      expect {
        described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "test-router", replica_count: 1)
      }.not_to raise_error
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "reconciles replicas and hops to wait_replicas" do
      expect(nx).to receive(:reconcile_replicas)
      expect(nx).to receive(:register_deadline).with("wait", 10 * 60)
      expect { nx.start }.to hop("wait_replicas")
    end
  end

  describe "#wait_replicas" do
    it "naps until all replicas are ready" do
      expect(replicas.first).to receive(:strand).and_return(instance_double(Strand, label: "start"))
      expect { nx.wait_replicas }.to nap(5)
    end

    it "hops when all replicas are ready" do
      expect { nx.wait_replicas }.to hop("wait")
    end
  end

  describe "#wait" do
    it "reconciles replicas and naps" do
      expect(nx).to receive(:reconcile_replicas)
      expect { nx.wait }.to nap(60)
    end
  end

  describe "#destroy" do
    let(:load_balancer) { instance_double(LoadBalancer) }
    let(:private_subnet) { instance_double(PrivateSubnet) }

    it "triggers destruction of resources and hops to self_destroy" do
      expect(inference_router).to receive(:load_balancer).and_return(load_balancer)
      expect(inference_router).to receive(:private_subnet).and_return(private_subnet)
      expect(nx).to receive(:register_deadline)
      expect(replicas).to all(receive(:incr_destroy))
      expect(load_balancer).to receive(:incr_destroy)
      expect(private_subnet).to receive(:incr_destroy)

      expect { nx.destroy }.to hop("self_destroy")
    end
  end

  describe "#self_destroy" do
    it "waits until replicas are destroyed" do
      expect { nx.self_destroy }.to nap(10)
    end

    it "destroys the inference_router" do
      allow(nx).to receive(:replicas).and_return([])
      expect(inference_router).to receive(:destroy)
      expect { nx.self_destroy }.to exit({"msg" => "inference router is deleted"})
    end
  end

  describe "#reconcile_replicas" do
    it "assembles new replicas if actual count is less than desired" do
      allow(inference_router).to receive(:replica_count).and_return(3)
      expect(replicas).to all(receive(:destroy_set?).and_return(false))
      expect(Prog::Ai::InferenceRouterReplicaNexus).to receive(:assemble).with(inference_router.id)
      nx.reconcile_replicas
    end

    it "destroys older excess replicas if actual count is more than desired" do
      allow(inference_router).to receive(:replica_count).and_return(1)
      expect(replicas).to all(receive(:destroy_set?).at_least(:once).and_return(false))
      expect(replicas[0]).to receive(:created_at).and_return(Time.now)
      expect(replicas[1]).to receive(:created_at).and_return(Time.now + 1)
      expect(replicas[0]).to receive(:incr_destroy)
      expect(replicas[1]).not_to receive(:incr_destroy)
      nx.reconcile_replicas
    end

    it "destroys excess replicas not in wait if actual count is more than desired" do
      allow(inference_router).to receive(:replica_count).and_return(1)
      expect(replicas).to all(receive(:destroy_set?).at_least(:once).and_return(false))
      expect(replicas[0]).to receive(:strand).and_return(instance_double(Strand, label: "start")).at_least(:once)
      expect(replicas[0]).to receive(:created_at).and_return(Time.now + 1)
      expect(replicas[1]).to receive(:created_at).and_return(Time.now)
      expect(replicas[0]).to receive(:incr_destroy)
      expect(replicas[1]).not_to receive(:incr_destroy)
      nx.reconcile_replicas
    end

    it "does nothing if actual equals to desired replica count" do
      allow(inference_router).to receive(:replica_count).and_return(2)
      expect(replicas).to all(receive(:destroy_set?).at_least(:once).and_return(false))
      expect(replicas).not_to include(receive(:incr_destroy))
      nx.reconcile_replicas
    end
  end
end
