# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::DnsZone do
  subject(:dns_zone_test) { described_class.new(described_class.assemble) }

  let(:dns_service_project_id) { "11111111-1111-1111-1111-111111111111" }
  let(:kubernetes_service_project_id) { "22222222-2222-2222-2222-222222222222" }
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
  end

  describe ".assemble" do
    it "creates a strand and the supporting projects" do
      st = described_class.assemble
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
      expect(st.stack.first["zone_name"]).to eq(zone_name)
      expect(Project[dns_service_project_id].id).to eq "11111111-1111-1111-1111-111111111111"
      expect(Project[kubernetes_service_project_id].id).to eq "22222222-2222-2222-2222-222222222222"
    end

    it "reuses existing service projects" do
      Project.create_with_id(dns_service_project_id, name: "Dns-Service-Project")
      Project.create_with_id(kubernetes_service_project_id, name: "Ubicloud-Kubernetes-Resources")
      expect { described_class.assemble }.not_to change(Project, :count)
    end

    it "fails when the kubernetes service hostname is missing" do
      allow(Config).to receive(:kubernetes_service_hostname).and_return(nil)
      expect { described_class.assemble }.to raise_error(RuntimeError, /kubernetes_service_hostname must be set/)
    end

    it "fails when the dns service project id is missing" do
      allow(Config).to receive(:dns_service_project_id).and_return(nil)
      expect { described_class.assemble }.to raise_error(RuntimeError, /dns_service_project_id must be set/)
    end

    it "fails when the cloudflare api token is missing" do
      allow(Config).to receive(:e2e_cloudflare_api_token).and_return(nil)
      expect { described_class.assemble }.to raise_error(RuntimeError, /e2e_cloudflare_api_token must be set/)
    end

    it "fails when the cloudflare parent zone name is missing" do
      allow(Config).to receive(:e2e_cloudflare_parent_zone_name).and_return(nil)
      expect { described_class.assemble }.to raise_error(RuntimeError, /e2e_cloudflare_parent_zone_name must be set/)
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
      Excon.stub({path: "/client/v4/zones", method: :get, query: {name: parent_zone_name}}, {status: 200, body: {result: [{id: "parent-zone-id"}]}.to_json})
      Excon.stub(
        {path: "/client/v4/zones/parent-zone-id/dns_records", method: :post, body: {type: "A", name: "ns-e2e.#{parent_zone_name}", content: vm.ip4.to_s, ttl:, proxied: false}.to_json},
        {status: 200, body: {result: {id: "rec-a"}}.to_json},
      )
      Excon.stub(
        {path: "/client/v4/zones/parent-zone-id/dns_records", method: :post, body: {type: "AAAA", name: "ns-e2e.#{parent_zone_name}", content: vm.ip6.to_s, ttl:, proxied: false}.to_json},
        {status: 200, body: {result: {id: "rec-aaaa"}}.to_json},
      )
      Excon.stub(
        {path: "/client/v4/zones/parent-zone-id/dns_records", method: :post, body: {type: "NS", name: zone_name, content: "ns-e2e.#{parent_zone_name}", ttl:, proxied: false}.to_json},
        {status: 200, body: {result: {id: "rec-ns"}}.to_json},
      )

      expect { dns_zone_test.register_cloudflare_records }.to hop("wait_dns_propagation")
      expect(frame_value(dns_zone_test, "cloudflare_zone_id")).to eq("parent-zone-id")
      expect(frame_value(dns_zone_test, "cloudflare_record_ids")).to eq(["rec-a", "rec-aaaa", "rec-ns"])
    end

    it "fails when the knot vm has disappeared" do
      refresh_frame(dns_zone_test, new_values: {"dns_server_id" => nil})
      expect { dns_zone_test.register_cloudflare_records }.to raise_error(RuntimeError, /Knot VM is missing/)
    end
  end

  describe "#wait_dns_propagation" do
    let(:current_ip) { "203.0.113.10" }
    let(:stale_ip) { "198.51.100.99" }
    let(:vm) {
      vm = create_vm(ip4_enabled: true)
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "#{current_ip}/32")
      vm.reload
    }
    let(:ds) {
      server = DnsServer.create(name: "ns-e2e.#{parent_zone_name}")
      server.add_vm(vm)
      server
    }
    let(:current_a) { instance_double(Resolv::DNS::Resource::IN::A, address: Resolv::IPv4.create(current_ip)) }
    let(:stale_a) { instance_double(Resolv::DNS::Resource::IN::A, address: Resolv::IPv4.create(stale_ip)) }
    let(:dns) { instance_double(Resolv::DNS) }

    before do
      refresh_frame(dns_zone_test, new_values: {"dns_server_id" => ds.id})
      allow(dns).to receive(:timeouts=)
    end

    it "fails fast when the knot vm has disappeared" do
      refresh_frame(dns_zone_test, new_values: {"dns_server_id" => nil})
      expect { dns_zone_test.wait_dns_propagation }.to raise_error(RuntimeError, /Knot VM is missing/)
    end

    it "naps while no public resolver returns an A record yet" do
      expect(Resolv::DNS).to receive(:open).and_yield(dns)
      expect(dns).to receive(:getresources).and_return([])

      expect { dns_zone_test.wait_dns_propagation }.to nap(10)
    end

    it "naps when a resolver still serves a stale A record from cache" do
      expect(Resolv::DNS).to receive(:open).and_yield(dns)
      expect(dns).to receive(:getresources).and_return([stale_a])

      expect { dns_zone_test.wait_dns_propagation }.to nap(10)
    end

    it "naps when only some resolvers return the current A record" do
      call_count = 0
      allow(Resolv::DNS).to receive(:open) do |&block|
        call_count += 1
        block.call(dns)
      end
      allow(dns).to receive(:getresources) {
        (call_count == 1) ? [current_a] : [stale_a]
      }

      expect { dns_zone_test.wait_dns_propagation }.to nap(10)
    end

    it "naps when a resolver errors out" do
      expect(Resolv::DNS).to receive(:open).and_raise(Resolv::ResolvTimeout)
      expect { dns_zone_test.wait_dns_propagation }.to nap(10)
    end

    it "hops to wait once every public resolver returns the current A record" do
      expect(Resolv::DNS).to receive(:open).and_yield(dns).twice
      expect(dns).to receive(:getresources).and_return([current_a]).twice

      expect { dns_zone_test.wait_dns_propagation }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps when no destroy signal is set" do
      expect { dns_zone_test.wait }.to nap(10)
    end

    it "hops to trigger_destroy when the semaphore is set" do
      strand = described_class.assemble
      Semaphore.incr(strand.id, :destroy_and_verify)
      expect { described_class.new(strand).wait }.to hop("trigger_destroy")
    end
  end

  describe "#trigger_destroy" do
    let(:ds) { DnsServer.create(name: "ns-e2e.#{parent_zone_name}") }

    it "deletes cloudflare records, retires the knot vm, and hops to wait_destroy" do
      vm = Prog::Vm::Nexus.assemble(SshKey.generate.public_key, Project.create(name: "vm-test").id).subject
      vm.strand.update(label: "wait")
      ds.add_vm(vm)
      refresh_frame(dns_zone_test, new_values: {
        "dns_server_id" => ds.id,
        "cloudflare_zone_id" => "parent-zone-id",
        "cloudflare_record_ids" => ["rec-a", "rec-aaaa", "rec-ns"],
      })

      ["rec-a", "rec-aaaa", "rec-ns"].each do |rid|
        Excon.stub({path: "/client/v4/zones/parent-zone-id/dns_records/#{rid}", method: :delete}, {status: 200})
      end

      expect { dns_zone_test.trigger_destroy }.to hop("wait_destroy")
      expect(vm.destroy_set?).to be true
      expect(DB[:dns_servers_vms].where(vm_id: vm.id).count).to eq(0)
    end

    it "is a no-op on the knot vm when it was already retired in a prior attempt" do
      refresh_frame(dns_zone_test, new_values: {
        "dns_server_id" => ds.id,
        "cloudflare_zone_id" => "parent-zone-id",
        "cloudflare_record_ids" => [],
      })
      expect(ds).not_to receive(:retire_vm)
      expect { dns_zone_test.trigger_destroy }.to hop("wait_destroy")
    end
  end

  describe "#wait_destroy" do
    it "tears down the dns zone, server, and strand then pops" do
      Project.create_with_id(kubernetes_service_project_id, name: "Ubicloud-Kubernetes-Resources")
      ds = DnsServer.create(name: "ns-e2e.#{parent_zone_name}")
      dz = DnsZone.create(name: zone_name, project_id: kubernetes_service_project_id, neg_ttl: 30, last_purged_at: Time.now)
      dz.add_dns_server(ds)
      Strand.create_with_id(dz.id, prog: "DnsZone::DnsZoneNexus", label: "wait")
      dz.insert_record(record_name: "foo.#{zone_name}", type: "A", ttl: 30, data: "1.2.3.4")

      refresh_frame(dns_zone_test, new_values: {"dns_zone_id" => dz.id, "dns_server_id" => ds.id})

      expect { dns_zone_test.wait_destroy }.to exit({"msg" => "Dns infrastructure destroyed"})
      expect(DnsZone[dz.id]).to be_nil
      expect(DnsServer[ds.id]).to be_nil
      expect(Strand[dz.id]).to be_nil
      expect(DB[:dns_record].where(dns_zone_id: dz.id).count).to eq(0)
      expect(DB[:dns_servers_dns_zones].where(dns_zone_id: dz.id).count).to eq(0)
    end

    it "pops cleanly when nothing was registered" do
      refresh_frame(dns_zone_test, new_values: {"dns_zone_id" => nil, "dns_server_id" => nil})
      expect { dns_zone_test.wait_destroy }.to exit({"msg" => "Dns infrastructure destroyed"})
    end
  end

  describe "#failed" do
    it "naps" do
      expect { dns_zone_test.failed }.to nap(15)
    end
  end
end
