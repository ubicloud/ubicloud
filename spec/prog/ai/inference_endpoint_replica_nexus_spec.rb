# frozen_string_literal: true

require "spec_helper"
require_relative "../../../prog/ai/inference_endpoint_replica_nexus"

RSpec.describe Prog::Ai::InferenceEndpointReplicaNexus do
  subject(:nx) { described_class.new(Strand.create(id: "5943c405-0165-471e-93d5-20203e585aaf", prog: "Prog::Ai::InferenceEndpointReplicaNexus", label: "start")) }

  let(:inference_endpoint) {
    instance_double(InferenceEndpoint, id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77", replica_count: 2)
  }

  let(:vm) {
    instance_double(
      Vm,
      id: "fe4478f9-9454-466f-be7b-3cff302a4716",
      sshable: sshable,
      ephemeral_net4: "1.2.3.4",
      private_subnets: [instance_double(PrivateSubnet)]
    )
  }

  let(:replica) {
    instance_double(
      InferenceEndpointReplica,
      id: "a338f7fb-c608-49d2-aeb4-433dc1e8b9fe",
      ubid: "theubid",
      inference_endpoint: inference_endpoint,
      vm: vm
    )
  }

  let(:sshable) { instance_double(Sshable) }

  before do
    allow(nx).to receive_messages(vm: vm, inference_endpoint: inference_endpoint, inference_endpoint_replica: replica)
  end

  describe ".assemble" do
    it "creates replica and vm with sshable" do
      user_project = Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) }
      ie_project = Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) }
      Firewall.create_with_id(name: "inference-endpoint-firewall", location: "hetzner-fsn1").tap { _1.associate_with_project(ie_project) }

      expect(Config).to receive(:inference_endpoint_service_project_id).and_return(ie_project.id).at_least(:once)
      st_ie = Prog::Ai::InferenceEndpointNexus.assemble_with_model(
        project_id: user_project.id,
        location: "hetzner-fsn1",
        name: "ie1",
        model_id: "8b0b55b3-fb99-415f-8441-3abef2c2a200"
      )
      ie = st_ie.subject
      st = described_class.assemble(ie.id)
      replica = InferenceEndpointReplica[st.id]
      expect(replica).not_to be_nil
      expect(replica.vm).not_to be_nil
      expect(replica.vm.sshable).not_to be_nil
      expect(ie.replicas).to include(replica)
      expect(ie.load_balancer.vms).to include(replica.vm)
      expect(replica.vm.private_subnets).to include(ie.private_subnet)
      expect(replica.vm.boot_image).to eq(ie.boot_image)
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

    it "pops additional operations from stack" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect(nx.strand.stack).to receive(:count).and_return(2)
      expect { nx.before_run }.to exit({"msg" => "operation is cancelled due to the destruction of the inference endpoint replica"})
    end
  end

  describe "#start" do
    it "naps if vm not ready" do
      expect(replica.vm).to receive(:strand).and_return(instance_double(Strand, label: "prep"))
      expect { nx.start }.to nap(5)
    end

    it "update sshable host and hops" do
      expect(replica.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect { nx.start }.to hop("bootstrap_rhizome")
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds a bootstrap rhizome process" do
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "inference_endpoint", "subject_id" => replica.vm.id, "user" => "ubi"})
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    before { expect(nx).to receive(:reap) }

    it "hops to setup if there are no sub-programs running" do
      expect(nx).to receive(:leaf?).and_return true

      expect { nx.wait_bootstrap_rhizome }.to hop("setup")
    end

    it "donates if there are sub-programs running" do
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_bootstrap_rhizome }.to nap(1)
    end
  end

  describe "#setup" do
    it "triggers setup if setup command is not sent yet or failed" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo inference_endpoint/bin/setup-replica' setup", {stdin: "{\"inference_engine\":\"vllm\",\"inference_engine_params\":\"--some-params\",\"model\":\"llama\",\"replica_ubid\":\"theubid\",\"ssl_crt_path\":\"/ie/workdir/ubi_cert.pem\",\"ssl_key_path\":\"/ie/workdir/ubi_key.pem\",\"use_self_signed_cert\":false,\"gateway_port\":443}"}).twice
      expect(inference_endpoint).to receive(:engine).and_return("vllm").twice
      expect(inference_endpoint).to receive(:engine_params).and_return("--some-params").twice
      expect(inference_endpoint).to receive(:model_name).and_return("llama").twice
      expect(inference_endpoint).to receive(:load_balancer).and_return(instance_double(LoadBalancer, id: "lb-id", dst_port: 443)).twice

      # NotStarted
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check setup").and_return("NotStarted")
      expect { nx.setup }.to nap(5)

      # Failed
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check setup").and_return("Failed")
      expect { nx.setup }.to nap(5)
    end

    it "hops to wait_endpoint_up if setup command has succeeded" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check setup").and_return("Succeeded")
      expect { nx.setup }.to hop("wait_endpoint_up")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check setup").and_return("Unknown")
      expect { nx.setup }.to nap(5)
    end
  end

  describe "#wait_endpoint_up" do
    it "naps if vm is not in active set of load balancer" do
      lb = instance_double(LoadBalancer)
      expect(inference_endpoint).to receive(:load_balancer).and_return(lb)
      expect(lb).to receive(:reload).and_return(lb)
      expect(lb).to receive(:active_vms).and_return([])
      expect { nx.wait_endpoint_up }.to nap(5)
    end

    it "sets hops to wait when vm is in active set of load balancer" do
      lb = instance_double(LoadBalancer)
      expect(inference_endpoint).to receive(:load_balancer).and_return(lb)
      expect(lb).to receive(:reload).and_return(lb)
      expect(lb).to receive(:active_vms).and_return([vm])
      expect { nx.wait_endpoint_up }.to hop("wait")
    end
  end

  describe "#wait" do
    it "pings the inference gateway and naps" do
      expect(nx).to receive(:ping_gateway)
      expect { nx.wait }.to nap(60)
    end
  end

  describe "#destroy" do
    it "deletes resources and exits" do
      lb = instance_double(LoadBalancer)
      expect(inference_endpoint).to receive(:load_balancer).and_return(lb).twice
      expect(lb).to receive(:evacuate_vm).with(vm)
      expect(lb).to receive(:remove_vm).with(vm)

      expect(vm).to receive(:incr_destroy)
      expect(replica).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "inference endpoint replica is deleted"})
    end
  end

  describe "#ping_gateway" do
    it "for private endpoints" do
      expect(inference_endpoint).to receive(:is_public).and_return(false).twice
      expect(inference_endpoint).to receive(:ubid).and_return("ieubid")
      pj = instance_double(Project)
      expect(inference_endpoint).to receive(:project).and_return(pj)
      expect(pj).to receive(:ubid).and_return("theubid")
      expect(inference_endpoint).to receive(:api_keys).and_return([instance_double(ApiKey, key: "key", is_valid: true)])
      expect(sshable).to receive(:cmd).with("sudo curl -s -H \"Content-Type: application/json\" -X POST --data-binary @- --unix-socket /ie/workdir/inference-gateway.clover.sock http://localhost/control", {stdin: "{\"replica_ubid\":\"theubid\",\"public_endpoint\":false,\"projects\":[{\"ubid\":\"theubid\",\"api_keys\":[\"key\"],\"quota_rps\":100.0,\"quota_tps\":1000000.0}]}"}).and_return("{\"projects\":[]}")
      nx.ping_gateway
    end

    it "for public endpoints" do
      expect(inference_endpoint).to receive(:is_public).and_return(true).twice
      expect(inference_endpoint).to receive(:ubid).and_return("ieubid")
      expect(Project).to receive(:all).and_return([instance_double(Project, ubid: "someubid", get_ff_inference_endpoint: true, api_keys: [instance_double(ApiKey, key: "key", used_for: "inference_endpoint", is_valid: true)])])
      expect(sshable).to receive(:cmd).with("sudo curl -s -H \"Content-Type: application/json\" -X POST --data-binary @- --unix-socket /ie/workdir/inference-gateway.clover.sock http://localhost/control", {stdin: "{\"replica_ubid\":\"theubid\",\"public_endpoint\":true,\"projects\":[{\"ubid\":\"someubid\",\"api_keys\":[\"key\"],\"quota_rps\":1.0,\"quota_tps\":100.0}]}"}).and_return("{\"projects\":[]}")
      nx.ping_gateway
    end
  end
end
