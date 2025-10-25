# frozen_string_literal: true

require "spec_helper"
require_relative "../../../prog/ai/inference_router_replica_nexus"

RSpec.describe Prog::Ai::InferenceRouterReplicaNexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.create(prog: "Prog::Ai::InferenceRouterReplicaNexus", label: "start") }
  let(:project) { Project.create(name: "test") }
  let(:private_subnet) { PrivateSubnet.create(project_id: project.id, name: "test", location_id: Location::LEASEWEB_WDC02_ID, net6: "fe80::/64", net4: "192.168.0.0/24") }
  let(:load_balancer) { Prog::Vnet::LoadBalancerNexus.assemble(private_subnet.id, name: "test", src_port: 443, dst_port: 8443).subject }
  let(:dns_zone) { DnsZone.create(name: "test-dns-zone", project_id: project.id) }
  let(:cert) { Prog::Vnet::CertNexus.assemble(load_balancer.hostname, dns_zone.id).subject }
  let(:inference_router) {
    InferenceRouter.create(
      name: "ir-name",
      location: Location[Location::LEASEWEB_WDC02_ID],
      vm_size: "standard-2",
      replica_count: 2,
      project_id: project.id,
      load_balancer_id: load_balancer.id,
      private_subnet_id: private_subnet.id
    )
  }
  let!(:inference_router_model) {
    InferenceRouterModel.create(
      model_name: "test-model",
      prompt_billing_resource: "test-model-input",
      completion_billing_resource: "test-model-output",
      project_inflight_limit: 100,
      project_prompt_tps_limit: 10000,
      project_completion_tps_limit: 10000
    )
  }

  let(:vm) {
    vm_host = create_vm_host
    vm = Prog::Vm::Nexus.assemble("k y", project.id, name: "name", private_subnet_id: private_subnet.id).subject
    vm.update(vm_host_id: vm_host.id)
    vm
  }

  let(:replica) {
    InferenceRouterReplica.create(
      inference_router_id: inference_router.id,
      vm_id: vm.id
    )
  }

  let(:sshable) { instance_double(Sshable, host: "3.4.5.6") }

  before do
    allow(nx).to receive_messages(vm: vm, inference_router: inference_router, inference_router_replica: replica)
    allow(vm).to receive(:sshable).and_return(sshable)
    load_balancer.add_vm(vm)
    cert.update(cert: "cert", csr_key: Clec::Cert.ec_key.to_der)
    load_balancer.add_cert(cert)
  end

  describe ".assemble" do
    it "creates replica and vm with sshable" do
      user_project = Project.create(name: "default")
      ie_project = Project.create(name: "default")
      Firewall.create(name: "inference-router-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: ie_project.id)

      expect(Config).to receive(:inference_endpoint_service_project_id).and_return(ie_project.id).at_least(:once)
      st_ir = Prog::Ai::InferenceRouterNexus.assemble(
        project_id: user_project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "ir1"
      )
      ir = st_ir.subject
      st = described_class.assemble(ir.id)
      replica = InferenceRouterReplica[st.id]
      expect(replica).not_to be_nil
      expect(replica.vm).not_to be_nil
      expect(replica.vm.sshable).not_to be_nil
      expect(ir.replicas).to include(replica)
      expect(ir.load_balancer.vms).to include(replica.vm)
      expect(replica.vm.private_subnets).to include(ir.private_subnet)
      expect(replica.vm.boot_image).to eq("ubuntu-noble")
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
      expect { nx.before_run }.to exit({"msg" => "operation is cancelled due to the destruction of the inference router replica"})
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
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "inference_router", "subject_id" => replica.vm.id, "user" => "ubi"})
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "hops to setup if there are no sub-programs running" do
      expect { nx.wait_bootstrap_rhizome }.to hop("setup")
    end

    it "donates if there are sub-programs running" do
      Strand.create(parent_id: st.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_bootstrap_rhizome }.to nap(120)
    end
  end

  describe "#setup" do
    it "hops to wait_router_up if setup command has succeeded" do
      expect(nx).to receive(:update_config)
      expect(Config).to receive(:inference_router_access_token).and_return("dummy_access_token")
      expect(Config).to receive(:inference_router_release_tag).and_return("v0.1.0")
      expect(sshable).to receive(:cmd).with(
        "id -u inference-router >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin inference-router"
      )
      expect(sshable).to receive(:cmd).with(
        "sudo wget -O /ir/workdir/fetch_linux_amd64 https://github.com/gruntwork-io/fetch/releases/download/v0.4.6/fetch_linux_amd64"
      )
      expect(sshable).to receive(:cmd).with("sudo chmod +x /ir/workdir/fetch_linux_amd64")
      expect(sshable).to receive(:cmd).with(
        "sudo /ir/workdir/fetch_linux_amd64 --github-oauth-token=\"dummy_access_token\" --repo=\"https://github.com/ubicloud/inference-router\" --tag=\"v0.1.0\" --release-asset=\"inference-router-*\" /ir/workdir/"
      )
      expect(sshable).to receive(:cmd).with(
        "sudo tar -xzf /ir/workdir/inference-router-v0.1.0-x86_64-unknown-linux-gnu.tar.gz -C /ir/workdir"
      )
      expect(sshable).to receive(:cmd).with(
        "sudo chown -R inference-router:inference-router /ir/workdir"
      )
      expect(sshable).to receive(:cmd)
        .with(/sudo tee \/etc\/systemd\/system\/inference-router\.service > \/dev\/null << 'EOF'/)
      expect(sshable).to receive(:cmd).with("sudo systemctl daemon-reload")
      expect(sshable).to receive(:cmd).with("sudo systemctl enable --now inference-router")
      expect { nx.setup }.to hop("wait_router_up")
    end
  end

  describe "#wait_router_up" do
    it "naps if vm is not up" do
      LoadBalancerVmPort.first.update(state: "down")
      expect { nx.wait_router_up }.to nap(5)
    end

    it "sets hops to wait when vm is in active set of load balancer" do
      LoadBalancerVmPort.first.update(state: "up")
      expect { nx.wait_router_up }.to hop("wait")
    end
  end

  describe "#wait" do
    it "pings the inference inference_router and naps" do
      expect(nx).to receive(:available?).and_return(true)
      expect(nx).to receive(:ping_inference_router)
      expect { nx.wait }.to nap(120)
    end

    it "hops to unavailable if the replica is not available" do
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")
    end
  end

  describe "#unavailable" do
    it "creates a page if replica is unavailable" do
      LoadBalancerVmPort.first.update(state: "down")
      expect(Prog::PageNexus).to receive(:assemble)
      expect(inference_router).to receive(:maintenance_set?).and_return(false)
      expect { nx.unavailable }.to nap(30)
    end

    it "does not create a page if replica is in maintenance mode" do
      LoadBalancerVmPort.first.update(state: "down")
      expect(Prog::PageNexus).not_to receive(:assemble)
      expect(inference_router).to receive(:maintenance_set?).and_return(true)
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
    it "deletes resources and exits" do
      lb = instance_double(LoadBalancer)
      expect(inference_router).to receive(:load_balancer).and_return(lb).twice
      expect(lb).to receive(:evacuate_vm).with(vm)
      expect(lb).to receive(:remove_vm).with(vm)

      expect(vm).to receive(:incr_destroy)
      expect(replica).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "inference router replica is deleted"})
    end
  end

  describe "#ping_inference_router" do
    let(:projects) { [Project.create(name: "p1"), Project.create(name: "p2")] }

    it "for public routers" do
      ApiKey.create_inference_api_key(projects.first)
      ApiKey.create_inference_api_key(projects.last)
      InferenceRouterTarget.create(
        name: "test-target-a",
        host: "test-host-a",
        api_key: "test-key-a",
        inflight_limit: 10,
        priority: 1,
        inference_router_model_id: inference_router_model.id,
        inference_router_id: inference_router.id,
        enabled: true
      )
      InferenceRouterTarget.create(
        name: "test-target-b",
        host: "test-host-b",
        api_key: "test-key-b",
        inflight_limit: 10,
        priority: 1,
        extra_configs: {"tag1" => "value1", "tag2" => "value2"},
        inference_router_model_id: inference_router_model.id,
        inference_router_id: inference_router.id,
        enabled: true
      )
      InferenceRouterTarget.create(
        name: "test-target-c",
        host: "test-host-c",
        api_key: "test-key-c",
        inflight_limit: 10,
        priority: 2,
        inference_router_model_id: inference_router_model.id,
        inference_router_id: inference_router.id,
        enabled: true
      )
      InferenceRouterTarget.create(
        name: "test-target-d",
        host: "test-host-d",
        api_key: "test-key-d",
        inflight_limit: 10,
        priority: 2,
        inference_router_model_id: inference_router_model.id,
        inference_router_id: inference_router.id,
        enabled: false
      )
      expect(inference_router).to receive(:ubid).and_return("irubid")

      expected_projects = projects.map do |p|
        {
          "ubid" => p.ubid,
          "api_keys" => [Digest::SHA2.hexdigest(p.api_keys.first.key)]
        }
      end.sort_by { |p| p["ubid"] }
      expect(sshable).to receive(:cmd).with(
        "md5sum /ir/workdir/config.json | awk '{ print $1 }'"
      ).and_return("dummy_md5sum")
      expect(sshable).to receive(:cmd).with(
        "sudo mkdir -p /ir/workdir && sudo tee /ir/workdir/config.json > /dev/null",
        hash_including(stdin: a_string_matching(/"projects":/))
      ) do |command, options|
        json_sent = JSON.parse(options[:stdin])
        expect(json_sent["basic"]).to eq({})
        expect(json_sent["certificate"].transform_keys(&:to_sym)).to eq({
          cert: cert.cert,
          key: OpenSSL::PKey.read(cert.csr_key).to_pem
        })
        expect(json_sent["health_check"].transform_keys(&:to_sym)).to eq({
          check_frequency: "10s",
          consecutive_success: 2,
          consecutive_failure: 2
        })
        expect(json_sent["servers"].map { |h| h.transform_keys(&:to_sym) }).to eq([{
          name: "main-server",
          addr: "[::]:8443",
          locations: ["inference", "up"],
          threads: 0,
          metrics_path: "/metrics"
        }, {
          name: "admin-server",
          addr: "127.0.0.1:8080,::1:8080",
          locations: ["usage"],
          threads: 1
        }])
        expect(json_sent["locations"].map { |h| h.transform_keys(&:to_sym) }).to eq([
          {name: "up", path: "^/up$", app: "up"},
          {name: "inference", path: "^/v1/(chat/completions|completions|embeddings)$", app: "inference"},
          {name: "usage", path: "^/usage$", app: "usage"}
        ])
        expect(json_sent["routes"].map { |h| h.transform_keys(&:to_sym).except(:endpoints) }).to eq([{
          model_name: "test-model",
          project_inflight_limit: 100,
          project_prompt_tps_limit: 10000,
          project_completion_tps_limit: 10000
        }])
        expect(json_sent["routes"][0]["endpoints"].size).to eq(2)
        expect(json_sent["routes"][0]["endpoints"][0].sort_by { it["id"] }.map { |h| h.transform_keys(&:to_sym) }).to eq([{
          id: "test-target-a",
          host: "test-host-a",
          api_key: "test-key-a",
          inflight_limit: 10
        }, {
          id: "test-target-b",
          host: "test-host-b",
          api_key: "test-key-b",
          inflight_limit: 10,
          tag1: "value1",
          tag2: "value2"
        }])
        expect(json_sent["routes"][0]["endpoints"][1].map { |h| h.transform_keys(&:to_sym) }).to eq([{
          id: "test-target-c",
          host: "test-host-c",
          api_key: "test-key-c",
          inflight_limit: 10
        }])
        projects_sent = json_sent["projects"].sort_by { |p| p["ubid"] }
        expect(projects_sent).to eq(expected_projects)
      end
      expect(sshable).to receive(:cmd).with("sudo pkill -f -HUP inference-router")

      usage = [{
        "ubid" => replica.ubid,
        "request_count" => 1,
        "prompt_token_count" => 10,
        "completion_token_count" => 20
      }, {
        "ubid" => "anotherubid",
        "request_count" => 0,
        "prompt_token_count" => 0,
        "completion_token_count" => 0
      }]
      expect(sshable).to receive(:cmd).with("curl -k -m 10 --no-progress-meter https://localhost:8080/usage").and_return(usage.to_json)

      expect(nx).to receive(:update_billing_records).with(
        usage, "prompt_billing_resource", "prompt_token_count"
      )
      expect(nx).to receive(:update_billing_records).with(
        usage, "completion_billing_resource", "completion_token_count"
      )

      nx.ping_inference_router
    end

    it "for private routers (non-visible location) only includes projects with matching visible_locations" do
      inference_router.update(location_id: Location[name: "tr-ist-u1-tom"].id)

      p_allowed = Project.create(name: "allowed")
      p_blocked = Project.create(name: "blocked")
      ApiKey.create_inference_api_key(p_allowed)
      ApiKey.create_inference_api_key(p_blocked)

      p_allowed.set_ff_visible_locations ["tr-ist-u1-tom"]

      expect(sshable).to receive(:cmd).with(
        "md5sum /ir/workdir/config.json | awk '{ print $1 }'"
      ).and_return("dummy_md5sum")

      expect(sshable).to receive(:cmd).with(
        "sudo mkdir -p /ir/workdir && sudo tee /ir/workdir/config.json > /dev/null",
        hash_including(stdin: a_string_matching(/"projects":/))
      ) do |_, options|
        json_sent = JSON.parse(options[:stdin])

        # Collect sent project UBIDs for comparison
        sent_projects = json_sent["projects"]
        expect(sent_projects.size).to eq(1)

        expect(sent_projects.first["ubid"]).to eq(p_allowed.ubid)
        expect(sent_projects.first["api_keys"]).to eq(
          [Digest::SHA2.hexdigest(p_allowed.api_keys.first.key)]
        )

        ubids = sent_projects.map { |pr| pr["ubid"] }
        expect(ubids).not_to include(p_blocked.ubid)
      end

      expect(sshable).to receive(:cmd).with("sudo pkill -f -HUP inference-router")

      expect(sshable).to receive(:cmd)
        .with("curl -k -m 10 --no-progress-meter https://localhost:8080/usage")
        .and_return("[]")

      nx.ping_inference_router
    end

    it "skips config update when unchanged" do
      expect(inference_router).to receive(:ubid).and_return("irubid")
      expect(sshable).to receive(:cmd).with(
        "md5sum /ir/workdir/config.json | awk '{ print $1 }'"
      ).and_return("dd8a549def177e5a6cbedeb511b55208") # md5sum of the test config.
      expect(sshable).not_to receive(:cmd).with(
        "sudo mkdir -p /ir/workdir && sudo tee /ir/workdir/config.json > /dev/null",
        hash_including(stdin: a_string_matching(/"projects":/))
      )
      expect(sshable).not_to receive(:cmd).with("sudo pkill -f -HUP inference-router")
      expect(sshable).to receive(:cmd).with("curl -k -m 10 --no-progress-meter https://localhost:8080/usage").and_return("[]")
      nx.ping_inference_router
    end
  end

  describe "#update_billing_records" do
    let(:p1) { Project.create(name: "default") }

    it "updates billing records" do
      expect(BillingRecord.count).to eq(0)
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "model_name" => "test-model", "request_count" => 1, "prompt_token_count" => 10, "completion_token_count" => 20}],
        "prompt_billing_resource", "prompt_token_count"
      )
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "model_name" => "test-model", "request_count" => 1, "prompt_token_count" => 10, "completion_token_count" => 20}],
        "completion_billing_resource", "completion_token_count"
      )
      expect(BillingRecord.count).to eq(2)
      brs = BillingRecord.order(:billing_rate_id).all
      expect(brs[0].project_id).to eq(p1.id)
      expect(brs[0].resource_id).to eq(inference_router.id)
      expect(brs[0].billing_rate_id).to eq("ba80e171-0c24-4bf9-ac4f-36bdadb259c0")
      expect(brs[0].amount).to eq(10)
      expect(brs[1].project_id).to eq(p1.id)
      expect(brs[1].resource_id).to eq(inference_router.id)
      expect(brs[1].billing_rate_id).to eq("c8886006-9e15-4046-b46a-163851626f83")
      expect(brs[1].amount).to eq(20)
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "model_name" => "test-model", "request_count" => 1, "prompt_token_count" => 1, "completion_token_count" => 2}],
        "prompt_billing_resource", "prompt_token_count"
      )
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "model_name" => "test-model", "request_count" => 1, "prompt_token_count" => 1, "completion_token_count" => 2}],
        "completion_billing_resource", "completion_token_count"
      )
      expect(BillingRecord.count).to eq(2)
      expect(Integer(brs[0].reload.amount)).to eq(11)
      expect(Integer(brs[1].reload.amount)).to eq(22)
    end

    it "does not update for zero tokens" do
      expect(BillingRecord.count).to eq(0)
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "model_name" => "test-model", "request_count" => 0, "prompt_token_count" => 0, "completion_token_count" => 0}],
        "prompt_billing_resource", "prompt_token_count"
      )
      nx.update_billing_records(
        [{"ubid" => p1.ubid, "model_name" => "test-model", "request_count" => 0, "prompt_token_count" => 0, "completion_token_count" => 0}],
        "completion_billing_resource", "completion_token_count"
      )
      expect(BillingRecord.count).to eq(0)
    end

    it "failure in updating single record doesn't impact others" do
      p2 = Project.create(name: "default")
      expect(BillingRecord).to receive(:create).once.ordered.with(hash_including(project_id: p1.id)).and_raise(Sequel::DatabaseConnectionError)
      expect(BillingRecord).to receive(:create).once.ordered.with(hash_including(project_id: p2.id)).and_call_original
      expect(BillingRecord.count).to eq(0)
      nx.update_billing_records(
        [
          {"ubid" => p1.ubid, "model_name" => "test-model", "request_count" => 1, "prompt_token_count" => 2, "completion_token_count" => 3},
          {"ubid" => p2.ubid, "model_name" => "test-model", "request_count" => 1, "prompt_token_count" => 2, "completion_token_count" => 3}
        ],
        "prompt_billing_resource", "prompt_token_count"
      )
      expect(BillingRecord.count).to eq(1)
      br = BillingRecord.first
      expect(br.project_id).to eq(p2.id)
    end
  end
end
