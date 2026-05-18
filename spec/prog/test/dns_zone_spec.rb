# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::DnsZone do
  subject(:dns_zone_test) { described_class.new(described_class.assemble(Config.kubernetes_service_hostname, Config.kubernetes_service_project_id)) }

  let(:dns_service_project_id) { Project.generate_uuid }
  let(:kubernetes_service_project_id) { Project.generate_uuid }
  let(:zone_name) { "kubernetes.e2e.tahcloud.com" }
  let(:parent_zone_name) { "tahcloud.com" }
  let(:cloudflare_token) { "cf-token" }

  before do
    allow(Config).to receive_messages(
      kubernetes_service_hostname: zone_name,
      dns_service_project_id:,
      kubernetes_service_project_id:,
      e2e_cloudflare_api_token: cloudflare_token,
      e2e_cloudflare_parent_zone_name: parent_zone_name,
    )
    Project.create_with_id(Config.kubernetes_service_project_id, name: "Kubernetes-Service-Project")
  end

  describe ".assemble" do
    it "creates a strand and the supporting projects" do
      st = described_class.assemble(Config.kubernetes_service_hostname, Config.kubernetes_service_project_id)
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
      expect(st.stack.first["zone_name"]).to eq(zone_name)
      expect(st.stack.first["project_id"]).to eq(Config.kubernetes_service_project_id)
      expect(Project[dns_service_project_id].id).not_to be_nil
    end

    it "reuses existing service projects" do
      Project.create_with_id(dns_service_project_id, name: "Dns-Service-Project")
      expect { described_class.assemble(Config.kubernetes_service_hostname, Config.kubernetes_service_project_id) }.not_to change(Project, :count)
    end

    it "fails when the zone name is not provided" do
      expect { described_class.assemble(nil, Config.kubernetes_service_project_id) }.to raise_error(RuntimeError, "zone_name must be set")
      expect { described_class.assemble("", Config.kubernetes_service_project_id) }.to raise_error(RuntimeError, "zone_name must be set")
    end

    it "fails when the dns service project id is missing" do
      allow(Config).to receive(:dns_service_project_id).and_return(nil)
      expect { described_class.assemble(Config.kubernetes_service_hostname, Config.kubernetes_service_project_id) }.to raise_error(RuntimeError, "Config.dns_service_project_id must be set")
    end

    it "fails when the cloudflare api token is missing" do
      allow(Config).to receive(:e2e_cloudflare_api_token).and_return(nil)
      expect { described_class.assemble(Config.kubernetes_service_hostname, Config.kubernetes_service_project_id) }.to raise_error(RuntimeError, "Config.e2e_cloudflare_api_token must be set")
    end

    it "fails when the cloudflare parent zone name is missing" do
      allow(Config).to receive(:e2e_cloudflare_parent_zone_name).and_return(nil)
      expect { described_class.assemble(Config.kubernetes_service_hostname, Config.kubernetes_service_project_id) }.to raise_error(RuntimeError, "Config.e2e_cloudflare_parent_zone_name must be set")
    end

    it "fails when the provided project_id does not exist" do
      expect { described_class.assemble(Config.kubernetes_service_hostname, Project.generate_uuid) }.to raise_error(RuntimeError, "Provided project_id does not exist")
    end
  end

  describe "#start" do
    it "provisions a knot vm and hops to wait_setup" do
      expect { dns_zone_test.start }.to hop("wait_setup")

      dz = DnsZone[name: zone_name]
      expect(dz).not_to be_nil
      expect(dz.project_id).to eq(kubernetes_service_project_id)
      expect(dz.neg_ttl).to eq(30)
      expect(dz.dns_servers.count).to eq(1)
      expect(dz.dns_servers.first.name).to eq("ns-e2e.#{parent_zone_name}")
      expect(Strand[dz.id].prog).to eq("DnsZone::DnsZoneNexus")
      expect(Strand[frame_value(dns_zone_test, "setup_strand_id")]).not_to be_nil
    end
  end

  describe "#wait_setup" do
    it "naps while the setup strand is still running" do
      setup_st = Strand.create(prog: "DnsZone::SetupDnsServerVm", label: "start", stack: [{}])
      refresh_frame(dns_zone_test, new_values: {"setup_strand_id" => setup_st.id})
      expect { dns_zone_test.wait_setup }.to nap(10)
    end

    it "hops to register_cloudflare_records once the setup strand has popped" do
      refresh_frame(dns_zone_test, new_values: {"setup_strand_id" => "00000000-0000-0000-0000-000000000000"})
      expect { dns_zone_test.wait_setup }.to hop("register_cloudflare_records")
    end
  end

  describe "#register_cloudflare_records" do
    let(:vm) {
      vm = create_vm(ip4_enabled: true, ephemeral_net6: "2001:db8::/79")
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "203.0.113.10/32")
      vm.reload
    }
    let(:ds) {
      server = DnsServer.create(name: "ns-e2e.#{parent_zone_name}")
      server.add_vm(vm)
      server
    }

    before do
      refresh_frame(dns_zone_test, new_values: {"dns_server_id" => ds.id})
    end

    it "registers NS, A, and AAAA records at the minimum TTL and stores their ids" do
      ttl = described_class::CLOUDFLARE_RECORD_TTL
      ns = "ns-e2e.#{parent_zone_name}"
      records_path = "/client/v4/zones/parent-zone-id/dns_records"
      Excon.stub({path: "/client/v4/zones", method: :get, query: {name: parent_zone_name}}, {status: 200, body: {result: [{id: "parent-zone-id"}]}.to_json})

      Excon.stub({path: records_path, method: :get, query: {name: ns, type: "A"}}, {status: 200, body: {result: []}.to_json})
      Excon.stub(
        {path: records_path, method: :post, body: {type: "A", name: ns, content: vm.ip4.to_s, ttl:, proxied: false}.to_json},
        {status: 200, body: {result: {id: "rec-a"}}.to_json},
      )

      Excon.stub({path: records_path, method: :get, query: {name: ns, type: "AAAA"}}, {status: 200, body: {result: []}.to_json})
      Excon.stub(
        {path: records_path, method: :post, body: {type: "AAAA", name: ns, content: vm.ip6.to_s, ttl:, proxied: false}.to_json},
        {status: 200, body: {result: {id: "rec-aaaa"}}.to_json},
      )

      Excon.stub({path: records_path, method: :get, query: {name: zone_name, type: "NS"}}, {status: 200, body: {result: []}.to_json})
      Excon.stub(
        {path: records_path, method: :post, body: {type: "NS", name: zone_name, content: ns, ttl:, proxied: false}.to_json},
        {status: 200, body: {result: {id: "rec-ns"}}.to_json},
      )

      expect { dns_zone_test.register_cloudflare_records }.to hop("insert_sentinel_records")
      expect(frame_value(dns_zone_test, "cloudflare_zone_id")).to eq("parent-zone-id")
      expect(frame_value(dns_zone_test, "cloudflare_record_ids")).to eq(["rec-a", "rec-aaaa", "rec-ns"])
    end
  end

  describe "#insert_sentinel_records" do
    it "stores a random sentinel name in the stack, inserts A and AAAA records, and hops to wait_dns_propagation" do
      dz = DnsZone.create(name: zone_name, project_id: kubernetes_service_project_id, neg_ttl: 30, last_purged_at: Time.now)
      refresh_frame(dns_zone_test, new_values: {"dns_zone_id" => dz.id})

      expect { dns_zone_test.insert_sentinel_records }.to hop("wait_dns_propagation")

      sentinel_name = frame_value(dns_zone_test, "sentinel_record_name")
      expect(sentinel_name).to start_with("_e2e_check_")
      expect(sentinel_name).to end_with(".#{zone_name}")
      expect(dz.records_dataset.where(type: "A").select_map([:name, :data])).to eq([["#{sentinel_name}.", described_class::SENTINEL_RECORD_IP4]])
      expect(dz.records_dataset.where(type: "AAAA").select_map([:name, :data])).to eq([["#{sentinel_name}.", described_class::SENTINEL_RECORD_IP6]])
    end
  end

  describe "#wait_dns_propagation" do
    let(:sentinel_name) { "_e2e_check_test1234.#{zone_name}" }
    let(:matching_a) { instance_double(Resolv::DNS::Resource::IN::A, address: Resolv::IPv4.create(described_class::SENTINEL_RECORD_IP4)) }
    let(:matching_aaaa) { instance_double(Resolv::DNS::Resource::IN::AAAA, address: Resolv::IPv6.create(described_class::SENTINEL_RECORD_IP6)) }
    let(:stale_a) { instance_double(Resolv::DNS::Resource::IN::A, address: Resolv::IPv4.create("198.51.100.99")) }
    let(:dns) { instance_double(Resolv::DNS) }

    before do
      refresh_frame(dns_zone_test, new_values: {"sentinel_record_name" => sentinel_name})
      allow(dns).to receive(:timeouts=)
    end

    it "naps while no public resolver returns the sentinel A record yet" do
      expect(Resolv::DNS).to receive(:open).and_yield(dns)
      expect(dns).to receive(:getresources).with(sentinel_name, Resolv::DNS::Resource::IN::A).and_return([])

      expect { dns_zone_test.wait_dns_propagation }.to nap(10)
    end

    it "naps when a resolver still serves a stale A record from cache" do
      expect(Resolv::DNS).to receive(:open).and_yield(dns)
      expect(dns).to receive(:getresources).with(sentinel_name, Resolv::DNS::Resource::IN::A).and_return([stale_a])

      expect { dns_zone_test.wait_dns_propagation }.to nap(10)
    end

    it "naps when A resolves but AAAA does not" do
      expect(Resolv::DNS).to receive(:open).and_yield(dns)
      expect(dns).to receive(:getresources).with(sentinel_name, Resolv::DNS::Resource::IN::A).and_return([matching_a])
      expect(dns).to receive(:getresources).with(sentinel_name, Resolv::DNS::Resource::IN::AAAA).and_return([])

      expect { dns_zone_test.wait_dns_propagation }.to nap(10)
    end

    it "naps when a resolver errors out" do
      expect(Resolv::DNS).to receive(:open).and_raise(Resolv::ResolvTimeout)
      expect { dns_zone_test.wait_dns_propagation }.to nap(10)
    end

    it "hops to wait once every public resolver returns both sentinel records" do
      expect(Resolv::DNS).to receive(:open).and_yield(dns).twice
      expect(dns).to receive(:getresources).with(sentinel_name, Resolv::DNS::Resource::IN::A).and_return([matching_a]).twice
      expect(dns).to receive(:getresources).with(sentinel_name, Resolv::DNS::Resource::IN::AAAA).and_return([matching_aaaa]).twice

      expect { dns_zone_test.wait_dns_propagation }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps when no destroy signal is set" do
      expect { dns_zone_test.wait }.to nap(10)
    end

    it "hops to trigger_destroy when the semaphore is set" do
      dns_zone_test.incr_destroy_and_verify
      expect { dns_zone_test.wait }.to hop("trigger_destroy")
    end
  end

  describe "#trigger_destroy" do
    it "deletes the cloudflare records, retires the knot vm, and hops to wait_destroy" do
      vm = Prog::Vm::Nexus.assemble(SshKey.generate.public_key, Project.create(name: "vm-test").id).subject
      vm.strand.update(label: "wait")
      ds = DnsServer.create(name: "ns-e2e.#{parent_zone_name}")
      ds.add_vm(vm)
      refresh_frame(dns_zone_test, new_values: {
        "dns_server_id" => ds.id,
        "cloudflare_zone_id" => "parent-zone-id",
        "cloudflare_record_ids" => ["rec-a", "rec-aaaa", "rec-ns"],
      })

      ["rec-a", "rec-aaaa", "rec-ns"].each do |rid|
        Excon.stub({path: "/client/v4/zones/parent-zone-id/dns_records/#{rid}", method: :delete}, {status: 200})
      end

      expect { dns_zone_test.trigger_destroy }
        .to hop("wait_destroy")
        .and change { DB[:dns_servers_vms].where(vm_id: vm.id).count }.from(1).to(0)
      expect(vm.destroy_set?).to be true
    end
  end

  describe "#wait_destroy" do
    it "tears down the dns zone and destroys the dns server then pops" do
      ds = DnsServer.create(name: "ns-e2e.#{parent_zone_name}")
      dz = DnsZone.create(name: zone_name, project_id: kubernetes_service_project_id, neg_ttl: 30, last_purged_at: Time.now)
      dz.add_dns_server(ds)
      Strand.create_with_id(dz.id, prog: "DnsZone::DnsZoneNexus", label: "wait")
      dz.insert_record(record_name: "foo.#{zone_name}", type: "A", ttl: 30, data: "1.2.3.4")

      refresh_frame(dns_zone_test, new_values: {"dns_zone_id" => dz.id, "dns_server_id" => ds.id})

      expect { dns_zone_test.wait_destroy }
        .to exit({"msg" => "Dns infrastructure destroyed"})
        .and change { DB[:dns_record].where(dns_zone_id: dz.id).count }.from(1).to(0)
        .and change { DB[:dns_servers_dns_zones].where(dns_zone_id: dz.id).count }.from(1).to(0)
      expect(DnsZone[dz.id]).to be_nil
      expect(DnsServer[ds.id]).to be_nil
      expect(Strand[dz.id]).to be_nil
    end
  end

  describe "#failed" do
    it "naps" do
      expect { dns_zone_test.failed }.to nap(15)
    end
  end
end
