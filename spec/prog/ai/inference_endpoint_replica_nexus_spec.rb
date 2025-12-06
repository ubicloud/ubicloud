# frozen_string_literal: true

require "spec_helper"
require_relative "../../../prog/ai/inference_endpoint_replica_nexus"

RSpec.describe Prog::Ai::InferenceEndpointReplicaNexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.create(prog: "Prog::Ai::InferenceEndpointReplicaNexus", label: "start") }

  let(:project) { Project.create(name: "test") }
  let(:private_subnet) { PrivateSubnet.create(project_id: project.id, name: "test", location_id: Location::HETZNER_HEL1_ID, net6: "fe80::/64", net4: "192.168.0.0/24") }
  let(:load_balancer) { Prog::Vnet::LoadBalancerNexus.assemble(private_subnet.id, name: "test", src_port: 443, dst_port: 8443).subject }

  let(:inference_endpoint) {
    InferenceEndpoint.create(
      model_name: "test-model",
      replica_count: 2,
      is_public: true,
      location: Location[name: "hetzner-ai"],
      name: "ie-name",
      engine: "vllm",
      engine_params: "--some-params",
      external_config: {"some" => "config"},
      boot_image: "image",
      max_requests: 500,
      max_project_rps: 100,
      max_project_tps: 10000,
      vm_size: "size",
      storage_volumes: [],
      project_id: project.id,
      load_balancer_id: load_balancer.id,
      private_subnet_id: private_subnet.id
    )
  }

  let(:vm) {
    vm_host = create_vm_host
    vm = Prog::Vm::Nexus.assemble("k y", project.id, name: "name", private_subnet_id: private_subnet.id).subject
    vm.update(vm_host_id: vm_host.id)
    vm
  }

  let(:replica) {
    InferenceEndpointReplica.create(
      inference_endpoint_id: inference_endpoint.id,
      vm_id: vm.id
    )
  }

  let(:sshable) { instance_double(Sshable, host: "3.4.5.6") }

  before do
    allow(nx).to receive_messages(vm: vm, inference_endpoint: inference_endpoint, inference_endpoint_replica: replica)
    allow(vm).to receive(:sshable).and_return(sshable)
    load_balancer.add_vm(vm)
  end

  describe ".assemble" do
    it "creates replica and vm with sshable" do
      user_project = Project.create(name: "default")
      ie_project = Project.create(name: "default")
      Firewall.create(name: "inference-endpoint-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: ie_project.id)

      expect(Config).to receive(:inference_endpoint_service_project_id).and_return(ie_project.id).at_least(:once)
      st_ie = Prog::Ai::InferenceEndpointNexus.assemble_with_model(
        project_id: user_project.id,
        location_id: Location::HETZNER_FSN1_ID,
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
      expect(nx).to receive(:incr_destroying)
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if already in the wait_children_destroyed state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("wait_children_destroyed")
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
      vm.strand.update(label: "prep")
      expect { nx.start }.to nap(5)
    end

    it "update sshable host and hops" do
      vm.strand.update(label: "wait")
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
    it "hops to setup if there are no sub-programs running" do
      expect { nx.wait_bootstrap_rhizome }.to hop("download_lb_cert")
    end

    it "donates if there are sub-programs running" do
      Strand.create(parent_id: st.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_bootstrap_rhizome }.to nap(120)
    end
  end

  describe "#download_lb_cert" do
    it "downloads lb cert and hops to setup_external" do
      expect(sshable).to receive(:cmd).with("sudo inference_endpoint/bin/download-lb-cert")
      expect { nx.download_lb_cert }.to hop("setup_external")
    end
  end

  describe "#setup_external" do
    it "hops to setup for vllm" do
      expect { nx.setup_external }.to hop("setup")
    end

    it "creates a pod for runpod" do
      expect(inference_endpoint).to receive(:engine).and_return "runpod"
      expect(Config).to receive(:operator_ssh_public_keys).and_return "operator ssh key"
      stub_request(:post, "https://api.runpod.io/graphql")
        .with(
          body: "{\"query\":\"query Pods { myself { pods { id name runtime  { ports { ip isIpPublic privatePort publicPort type } } } } }\"}",
          headers: {
            "Accept-Encoding" => "deflate, gzip",
            "Authorization" => "Bearer ",
            "Content-Type" => "application/json",
            "Host" => "api.runpod.io"
          }
        )
        .to_return(status: 200, body: {data: {myself: {pods: []}}}.to_json, headers: {})

      stub_request(:post, "https://api.runpod.io/graphql")
        .with(
          body: "{\"query\":\"mutation {\\n  podFindAndDeployOnDemand(\\n    input: {\\n      cloudType: ALL\\n      dataCenterId: \\\"\\\"\\n      gpuCount: \\n      gpuTypeId: \\\"\\\"\\n      containerDiskInGb: \\n      minVcpuCount: \\n      minMemoryInGb: \\n      imageName: \\\"\\\"\\n      name: \\\"#{replica.ubid}\\\"\\n      volumeInGb: 0\\n      ports: \\\"22/tcp\\\"\\n      env: [\\n        { key: \\\"HF_TOKEN\\\", value: \\\"\\\" },\\n        { key: \\\"HF_HUB_ENABLE_HF_TRANSFER\\\", value: \\\"1\\\"},\\n        { key: \\\"MODEL_PATH\\\", value: \\\"/model\\\"},\\n        { key: \\\"MODEL_NAME_HF\\\", value: \\\"\\\"},\\n        { key: \\\"VLLM_PARAMS\\\", value: \\\"--served-model-name test-model --disable-log-requests --host 127.0.0.1 --some-params\\\"},\\n        { key: \\\"SSH_KEYS\\\", value: \\\"vm ssh key\\\\noperator ssh key\\\" }\\n      ]\\n    }\\n  ) {\\n    id\\n    imageName\\n    env\\n    machineId\\n    machine {\\n      podHostId\\n    }\\n  }\\n}\\n\"}",
          headers: {
            "Accept-Encoding" => "deflate, gzip",
            "Authorization" => "Bearer ",
            "Content-Type" => "application/json",
            "Host" => "api.runpod.io"
          }
        )
        .to_return(status: 200, body: {"data" => {"podFindAndDeployOnDemand" => {"id" => "thepodid"}}}.to_json, headers: {})
      expect(replica).to receive(:update).with(external_state: {"pod_id" => "thepodid"})
      expect(sshable).to receive(:cmd).and_return("vm ssh key\n")
      expect { nx.setup_external }.to nap(10)
    end

    it "does not create a pod if one already exists" do
      expect(inference_endpoint).to receive(:engine).and_return "runpod"
      stub_request(:post, "https://api.runpod.io/graphql")
        .with(
          body: "{\"query\":\"query Pods { myself { pods { id name runtime  { ports { ip isIpPublic privatePort publicPort type } } } } }\"}",
          headers: {
            "Accept-Encoding" => "deflate, gzip",
            "Authorization" => "Bearer ",
            "Content-Type" => "application/json",
            "Host" => "api.runpod.io"
          }
        )
        .to_return(status: 200, body: {"data" => {"myself" => {"pods" => [{"name" => replica.ubid.to_s, "id" => "thepodid"}]}}}.to_json, headers: {})

      expect(replica).to receive(:update).with(external_state: {"pod_id" => "thepodid"})
      expect { nx.setup_external }.to nap(10)
    end

    it "hops to setup for runpod" do
      expect(inference_endpoint).to receive(:engine).and_return "runpod"
      allow(replica).to receive(:external_state).and_return({"pod_id" => "thepodid"})
      stub_request(:post, "https://api.runpod.io/graphql")
        .with(
          body: "{\"query\":\"query Pod { pod(input: {podId: \\\"thepodid\\\"}) { id name runtime  { ports { ip isIpPublic privatePort publicPort type } } } }\"}",
          headers: {
            "Accept-Encoding" => "deflate, gzip",
            "Authorization" => "Bearer ",
            "Content-Type" => "application/json",
            "Host" => "api.runpod.io"
          }
        )
        .to_return(status: 200, body: {"data" => {"pod" => {"id" => "thepodid", "runtime" => {"ports" => [{"type" => "tcp", "isIpPublic" => true, "publicPort" => 1234, "ip" => "1.2.3.4"}]}}}}.to_json, headers: {})

      expect(replica).to receive(:update).with(external_state: {ip: "1.2.3.4", pod_id: "thepodid", port: 1234})
      expect { nx.setup_external }.to hop("setup")
    end

    it "waits until runpod ip and port are available" do
      expect(inference_endpoint).to receive(:engine).and_return "runpod"
      allow(replica).to receive(:external_state).and_return({"pod_id" => "thepodid"})
      stub_request(:post, "https://api.runpod.io/graphql")
        .with(
          body: "{\"query\":\"query Pod { pod(input: {podId: \\\"thepodid\\\"}) { id name runtime  { ports { ip isIpPublic privatePort publicPort type } } } }\"}",
          headers: {
            "Accept-Encoding" => "deflate, gzip",
            "Authorization" => "Bearer ",
            "Content-Type" => "application/json",
            "Host" => "api.runpod.io"
          }
        )
        .to_return(status: 200, body: {"data" => {"pod" => {"id" => "thepodid", "runtime" => {"ports" => [{"type" => "tcp", "isIpPublic" => false, "publicPort" => 1234, "ip" => "1.2.3.4"}]}}}}.to_json, headers: {})
      expect { nx.setup_external }.to nap(10)
    end

    it "raises an error if runpod pod id is unexpected" do
      expect(inference_endpoint).to receive(:engine).and_return "runpod"
      allow(replica).to receive(:external_state).and_return({"pod_id" => "thepodid"})
      stub_request(:post, "https://api.runpod.io/graphql")
        .with(
          body: "{\"query\":\"query Pod { pod(input: {podId: \\\"thepodid\\\"}) { id name runtime  { ports { ip isIpPublic privatePort publicPort type } } } }\"}",
          headers: {
            "Accept-Encoding" => "deflate, gzip",
            "Authorization" => "Bearer ",
            "Content-Type" => "application/json",
            "Host" => "api.runpod.io"
          }
        )
        .to_return(status: 200, body: {"data" => {"pod" => {"id" => "anotherpodid", "runtime" => {"ports" => [{"type" => "tcp", "isIpPublic" => false, "publicPort" => 1234, "ip" => "1.2.3.4"}]}}}}.to_json, headers: {})
      expect { nx.setup_external }.to raise_error("BUG: unexpected pod id")
    end

    it "raises an error if pod cannot be found" do
      expect(inference_endpoint).to receive(:engine).and_return "runpod"
      allow(replica).to receive(:external_state).and_return({"pod_id" => "thepodid"})
      stub_request(:post, "https://api.runpod.io/graphql")
        .with(
          body: "{\"query\":\"query Pod { pod(input: {podId: \\\"thepodid\\\"}) { id name runtime  { ports { ip isIpPublic privatePort publicPort type } } } }\"}",
          headers: {
            "Accept-Encoding" => "deflate, gzip",
            "Authorization" => "Bearer ",
            "Content-Type" => "application/json",
            "Host" => "api.runpod.io"
          }
        )
        .to_return(status: 200, body: {"data" => {}}.to_json, headers: {})
      expect { nx.setup_external }.to raise_error("BUG: pod not found")
    end
  end

  describe "#setup" do
    it "triggers setup if setup command is not sent yet or failed" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo inference_endpoint/bin/setup-replica' setup", {stdin: "{\"engine_start_cmd\":\"/opt/miniconda/envs/vllm/bin/vllm serve /ie/models/model --served-model-name llama --disable-log-requests --host 127.0.0.1 --some-params\",\"replica_ubid\":\"#{replica.ubid}\",\"ssl_crt_path\":\"/ie/workdir/ssl/ubi_cert.pem\",\"ssl_key_path\":\"/ie/workdir/ssl/ubi_key.pem\",\"gateway_port\":8443,\"max_requests\":500}"}).twice
      expect(inference_endpoint).to receive(:gpu_count).and_return(1).twice
      expect(inference_endpoint).to receive(:engine).and_return("vllm").twice
      expect(inference_endpoint).to receive(:engine_params).and_return("--some-params").twice
      expect(inference_endpoint).to receive(:model_name).and_return("llama").twice

      # NotStarted
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check setup").and_return("NotStarted")
      expect { nx.setup }.to nap(5)

      # Failed
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check setup").and_return("Failed")
      expect { nx.setup }.to nap(5)
    end

    it "triggers setup for vllm with cpu if setup command is not sent yet or failed" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo inference_endpoint/bin/setup-replica' setup", {stdin: "{\"engine_start_cmd\":\"/opt/miniconda/envs/vllm-cpu/bin/vllm serve /ie/models/model --served-model-name llama --disable-log-requests --host 127.0.0.1 --some-params\",\"replica_ubid\":\"#{replica.ubid}\",\"ssl_crt_path\":\"/ie/workdir/ssl/ubi_cert.pem\",\"ssl_key_path\":\"/ie/workdir/ssl/ubi_key.pem\",\"gateway_port\":8443,\"max_requests\":500}"})
      expect(inference_endpoint).to receive(:gpu_count).and_return(0)
      expect(inference_endpoint).to receive(:engine).and_return("vllm")
      expect(inference_endpoint).to receive(:engine_params).and_return("--some-params")
      expect(inference_endpoint).to receive(:model_name).and_return("llama")

      # NotStarted
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check setup").and_return("NotStarted")
      expect { nx.setup }.to nap(5)
    end

    it "triggers setup for runpod if setup command is not sent yet or failed" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo inference_endpoint/bin/setup-replica' setup", {stdin: "{\"engine_start_cmd\":\"ssh -N -L 8000:localhost:8000 root@ -p  -i /ie/workdir/.ssh/runpod -o UserKnownHostsFile=/ie/workdir/.ssh/known_hosts -o StrictHostKeyChecking=accept-new\",\"replica_ubid\":\"#{replica.ubid}\",\"ssl_crt_path\":\"/ie/workdir/ssl/ubi_cert.pem\",\"ssl_key_path\":\"/ie/workdir/ssl/ubi_key.pem\",\"gateway_port\":8443,\"max_requests\":500}"}).twice
      expect(inference_endpoint).to receive(:engine).and_return("runpod").twice

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

    it "fails if inference engine is unsupported" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check setup").and_return("NotStarted")
      expect(inference_endpoint).to receive(:engine).and_return("unsupported engine")
      expect { nx.setup }.to raise_error("BUG: unsupported inference engine")
    end
  end

  describe "#wait_endpoint_up" do
    it "naps if vm is not up" do
      LoadBalancerVmPort.dataset.update(state: "down")
      expect { nx.wait_endpoint_up }.to nap(5)
    end

    it "sets hops to wait when vm is in active set of load balancer" do
      LoadBalancerVmPort.dataset.update(state: "up")
      expect { nx.wait_endpoint_up }.to hop("wait")
    end
  end

  describe "#wait" do
    it "pings the inference gateway and naps" do
      expect(nx).to receive(:available?).and_return(true)
      expect(nx).to receive(:ping_gateway)
      expect { nx.wait }.to nap(120)
    end

    it "hops to unavailable if the replica is not available" do
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")
    end
  end

  describe "#unavailable" do
    it "creates a page if replica is unavailable" do
      LoadBalancerVmPort.dataset.update(state: "down")
      expect(Prog::PageNexus).to receive(:assemble)
      expect(inference_endpoint).to receive(:maintenance_set?).and_return(false)
      expect { nx.unavailable }.to nap(30)
    end

    it "does not create a page if replica is in maintenance mode" do
      LoadBalancerVmPort.dataset.update(state: "down")
      expect(Prog::PageNexus).not_to receive(:assemble)
      expect(inference_endpoint).to receive(:maintenance_set?).and_return(true)
      expect { nx.unavailable }.to nap(30)
    end

    it "resolves the page if replica is available" do
      pg = instance_double(Page)
      expect(pg).to receive(:incr_resolve)
      expect(nx).to receive(:available?).and_return(true)
      expect(Page).to receive(:from_tag_parts).and_return(pg)
      expect { nx.unavailable }.to hop("wait")
    end

    it "does not resolves the page if there is none" do
      expect(nx).to receive(:available?).and_return(true)
      expect(Page).to receive(:from_tag_parts).and_return(nil)
      expect { nx.unavailable }.to hop("wait")
    end
  end

  describe "#destroy" do
    it "adds destroy semaphore to children and hops to wait_children_destroyed" do
      st = Strand.create(prog: "Prog::BootstrapRhizome", label: "start", parent_id: nx.strand.id)
      expect { nx.destroy }.to hop("wait_children_destroyed")
      expect(Semaphore.where(name: "destroy").select_order_map(:strand_id)).to eq [st.id]
    end

    it "deletes runpod pod if there is one" do
      expect(replica).to receive(:external_state).and_return({"pod_id" => "thepodid"})

      stub_request(:post, "https://api.runpod.io/graphql")
        .with(
          body: "{\"query\":\"mutation { podTerminate(input: {podId: \\\"thepodid\\\"}) }\"}",
          headers: {
            "Accept-Encoding" => "deflate, gzip",
            "Authorization" => "Bearer ",
            "Content-Type" => "application/json",
            "Host" => "api.runpod.io"
          }
        )
        .to_return(status: 200, body: "", headers: {})

      expect(replica).to receive(:update).with(external_state: "{}")

      expect { nx.destroy }.to hop("wait_children_destroyed")
    end
  end

  describe "#wait_children_destroyed" do
    it "naps if children still exist" do
      Strand.create(prog: "Prog::BootstrapRhizome", label: "start", parent_id: nx.strand.id)
      expect { nx.wait_children_destroyed }.to nap(5)
    end

    it "exits and destroys resources if no children exist" do
      lb = instance_double(LoadBalancer)
      expect(inference_endpoint).to receive(:load_balancer).and_return(lb).twice
      expect(lb).to receive(:evacuate_vm).with(vm)
      expect(lb).to receive(:remove_vm).with(vm)
      expect(vm).to receive(:incr_destroy)
      expect(replica).to receive(:destroy)
      expect { nx.wait_children_destroyed }.to exit({"msg" => "inference endpoint replica is deleted"})
    end
  end

  describe "#ping_gateway" do
    let(:projects) { [Project.create(name: "p1"), Project.create(name: "p2")] }

    before do
      ApiKey.create_inference_api_key(projects.first)
      ApiKey.create_inference_api_key(projects.last)
    end

    it "for private endpoints" do
      expect(inference_endpoint).to receive(:project).and_return(projects.first)
      expect(inference_endpoint).to receive(:is_public).and_return(false).twice
      expect(inference_endpoint).to receive(:ubid).and_return("ieubid")
      expect(nx).to receive(:update_billing_records).with(
        JSON.parse("[{\"ubid\":\"#{replica.ubid}\",\"request_count\":1,\"prompt_token_count\":10,\"completion_token_count\":20},{\"ubid\":\"anotherubid\",\"request_count\":0,\"prompt_token_count\":0,\"completion_token_count\":0}]"),
        "input", "prompt_token_count"
      )
      expect(nx).to receive(:update_billing_records).with(
        JSON.parse("[{\"ubid\":\"#{replica.ubid}\",\"request_count\":1,\"prompt_token_count\":10,\"completion_token_count\":20},{\"ubid\":\"anotherubid\",\"request_count\":0,\"prompt_token_count\":0,\"completion_token_count\":0}]"),
        "output", "completion_token_count"
      )
      expect(sshable).to receive(:cmd).with("sudo curl -m 10 --no-progress-meter -H \"Content-Type: application/json\" -X POST --data-binary @- --unix-socket /ie/workdir/inference-gateway.clover.sock http://localhost/control", {stdin: "{\"replica_ubid\":\"#{replica.ubid}\",\"public_endpoint\":false,\"projects\":[{\"ubid\":\"#{projects.first.ubid}\",\"api_keys\":[\"#{Digest::SHA2.hexdigest(projects.first.api_keys.first.key)}\"],\"quota_rps\":100,\"quota_tps\":10000}]}"}).and_return("{\"inference_endpoint\":\"1eqhk4b9gfq27gc5agxkq84bhr\",\"replica\":\"1rvtmbhd8cne6jpz3xxat7rsnr\",\"projects\":[{\"ubid\":\"#{replica.ubid}\",\"request_count\":1,\"prompt_token_count\":10,\"completion_token_count\":20},{\"ubid\":\"anotherubid\",\"request_count\":0,\"prompt_token_count\":0,\"completion_token_count\":0}]}")
      nx.ping_gateway
    end

    it "for public endpoints" do
      expect(inference_endpoint).to receive(:is_public).and_return(true).twice
      expect(inference_endpoint).to receive(:ubid).and_return("ieubid")

      expected_projects = [
        {"ubid" => projects.first.ubid, "api_keys" => [Digest::SHA2.hexdigest(projects.first.api_keys.first.key)], "quota_rps" => 100, "quota_tps" => 10000},
        {"ubid" => projects.last.ubid, "api_keys" => [Digest::SHA2.hexdigest(projects.last.api_keys.first.key)], "quota_rps" => 100, "quota_tps" => 10000}
      ].sort_by { |p| p["ubid"] }

      expect(sshable).to receive(:cmd) do |command, options|
        json_sent = JSON.parse(options[:stdin])
        projects_sent = json_sent["projects"].sort_by { |p| p["ubid"] }
        expect(projects_sent).to eq(expected_projects)
      end.and_return("{\"inference_endpoint\":\"1eqhk4b9gfq27gc5agxkq84bhr\",\"replica\":\"1rvtmbhd8cne6jpz3xxat7rsnr\",\"projects\":[{\"ubid\":\"#{replica.ubid}\",\"request_count\":1,\"prompt_token_count\":10,\"completion_token_count\":20},{\"ubid\":\"anotherubid\",\"request_count\":0,\"prompt_token_count\":0,\"completion_token_count\":0}]}")
      expect(nx).to receive(:update_billing_records).with(
        JSON.parse("[{\"ubid\":\"#{replica.ubid}\",\"request_count\":1,\"prompt_token_count\":10,\"completion_token_count\":20},{\"ubid\":\"anotherubid\",\"request_count\":0,\"prompt_token_count\":0,\"completion_token_count\":0}]"),
        "input", "prompt_token_count"
      )
      expect(nx).to receive(:update_billing_records).with(
        JSON.parse("[{\"ubid\":\"#{replica.ubid}\",\"request_count\":1,\"prompt_token_count\":10,\"completion_token_count\":20},{\"ubid\":\"anotherubid\",\"request_count\":0,\"prompt_token_count\":0,\"completion_token_count\":0}]"),
        "output", "completion_token_count"
      )

      nx.ping_gateway
    end
  end

  describe "#update_billing_records" do
    let(:p1) { Project.create(name: "default") }

    it "updates billing records" do
      expect(BillingRecord.count).to eq(0)
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "request_count" => 1, "prompt_token_count" => 10, "completion_token_count" => 20}],
        "input", "prompt_token_count"
      )
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "request_count" => 1, "prompt_token_count" => 10, "completion_token_count" => 20}],
        "output", "completion_token_count"
      )
      expect(BillingRecord.count).to eq(2)
      br, br2 = BillingRecord.order(:billing_rate_id).all
      expect(br.project_id).to eq(p1.id)
      expect(br.resource_id).to eq(inference_endpoint.id)
      expect(br.billing_rate_id).to eq("ba80e171-0c24-4bf9-ac4f-36bdadb259c0")
      expect(br.amount).to eq(10)
      expect(br2.project_id).to eq(p1.id)
      expect(br2.resource_id).to eq(inference_endpoint.id)
      expect(br2.billing_rate_id).to eq("c8886006-9e15-4046-b46a-163851626f83")
      expect(br2.amount).to eq(20)
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "request_count" => 1, "prompt_token_count" => 1, "completion_token_count" => 2}],
        "input", "prompt_token_count"
      )
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "request_count" => 1, "prompt_token_count" => 1, "completion_token_count" => 2}],
        "output", "completion_token_count"
      )
      expect(BillingRecord.count).to eq(2)
      expect(Integer(br.reload.amount)).to eq(11)
      expect(Integer(br2.reload.amount)).to eq(22)
    end

    it "does not update for zero tokens" do
      expect(BillingRecord.count).to eq(0)
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "request_count" => 0, "prompt_token_count" => 0, "completion_token_count" => 0}],
        "input", "prompt_token_count"
      )
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "request_count" => 0, "prompt_token_count" => 0, "completion_token_count" => 0}],
        "output", "completion_token_count"
      )
      expect(BillingRecord.count).to eq(0)
    end

    it "does not update if price is zero" do
      expect(BillingRate).to receive(:from_resource_properties).with("InferenceTokens", "#{inference_endpoint.model_name}-input", "global").and_return({"unit_price" => 0.0000000000})
      expect(BillingRate).to receive(:from_resource_properties).with("InferenceTokens", "#{inference_endpoint.model_name}-output", "global").and_return({"unit_price" => 0.0000000000})
      expect(BillingRecord.count).to eq(0)
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "request_count" => 1, "prompt_token_count" => 2, "completion_token_count" => 3}],
        "input", "prompt_token_count"
      )
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "request_count" => 1, "prompt_token_count" => 2, "completion_token_count" => 3}],
        "output", "completion_token_count"
      )
      expect(BillingRecord.count).to eq(0)
    end

    it "failure in updating single record doesn't impact others" do
      p2 = Project.create(name: "default")
      expect(BillingRecord).to receive(:create).once.ordered.with(hash_including(project_id: p1.id)).and_raise(Sequel::DatabaseConnectionError)
      expect(BillingRecord).to receive(:create).once.ordered.with(hash_including(project_id: p2.id)).and_call_original
      expect(BillingRecord.count).to eq(0)
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "request_count" => 1, "prompt_token_count" => 2, "completion_token_count" => 3}, {"ubid" => p2.ubid, "request_count" => 1, "prompt_token_count" => 2, "completion_token_count" => 3}],
        "input", "prompt_token_count"
      )
      expect(BillingRecord.count).to eq(1)
      br = BillingRecord.first
      expect(br.project_id).to eq(p2.id)
    end
  end
end
