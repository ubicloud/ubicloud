# frozen_string_literal: true

require "google/cloud/compute/v1"
require "google/apis/cloudresourcemanager_v3"

RSpec.describe Prog::Vnet::Gcp::UpdateFirewallRules do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.create(prog: "Vnet::Gcp::UpdateFirewallRules", label: "update_firewall_rules") }
  let(:vm) { instance_double(Vm, name: "testvm", ubid: "vmubid1") }
  let(:location) { instance_double(Location, name: "gcp-us-central1", ubid: "locationubid1", location_credential_gcp: credential) }
  let(:project) { instance_double(Project, ubid: "myprojectubid") }
  let(:vpc_name) { "ubicloud-#{project.ubid}-#{location.ubid}" }
  let(:nfp_client) { instance_double(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client) }
  let(:global_ops_client) { instance_double(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client) }
  let(:compute_client) { instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client) }
  let(:networks_client) { instance_double(Google::Cloud::Compute::V1::Networks::Rest::Client) }
  let(:crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }
  let(:regional_crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }
  let(:credential) {
    instance_double(LocationCredentialGcp,
      network_firewall_policies_client: nfp_client,
      global_operations_client: global_ops_client,
      compute_client:,
      networks_client:,
      crm_client:,
      project_id: "test-gcp-project")
  }
  let(:lro_op) { instance_double(Gapic::GenericLRO::Operation, name: "op-12345") }
  let(:done_op) { Google::Cloud::Compute::V1::Operation.new(status: :DONE) }

  let(:firewall) { instance_double(Firewall, id: "fw-id-1", ubid: "fwubid1") }
  let(:fw_tag_key_name) { "tagKeys/fw-123" }
  let(:fw_tag_value_name) { "tagValues/fw-tv-1" }
  let(:subnet_tag_key_name) { "tagKeys/subnet-123" }
  let(:subnet_tag_value_name) { "tagValues/subnet-tv-1" }

  let(:gcp_vpc) { instance_double(GcpVpc, name: vpc_name, firewall_policy_name: vpc_name, network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/1234567890") }
  let(:ps) { instance_double(PrivateSubnet, ubid: "subnetubid1", net4: NetAddr::IPv4Net.parse("10.0.0.0/26"), net6: NetAddr::IPv6Net.parse("fd10:9b0b:6b4b:8fbb::/64"), project:, location:, gcp_vpc:) }
  let(:nic) { instance_double(Nic, private_subnet: ps, private_ipv4: NetAddr::IPv4Net.parse("10.0.0.5/32")) }

  let(:crm_done_op) { instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "crm-op-1", response: {"name" => "tagKeys/created-1"}, error: nil) }
  let(:crm_tv_done_op) { instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "crm-op-2", response: {"name" => "tagValues/created-1"}, error: nil) }

  let(:network) { Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 1234567890) }
  let(:instance_obj) { Google::Cloud::Compute::V1::Instance.new(name: "testvm", id: 9876543210) }
  let(:project_obj) { instance_double(Google::Apis::CloudresourcemanagerV3::Project, name: "projects/73189733048") }

  before do
    nx.instance_variable_set(:@vm, vm)
    allow(vm).to receive_messages(location:, nics: [nic], nic:, ephemeral_net6: nil, destroy_set?: false)
    allow(credential).to receive(:regional_crm_client).and_return(regional_crm_client)
    allow(global_ops_client).to receive(:get).and_return(done_op)
    allow(networks_client).to receive(:get).and_return(network)
    allow(crm_client).to receive(:get_project).and_return(project_obj)
    allow(compute_client).to receive(:get).and_return(instance_obj)
  end

  describe "#before_run" do
    it "pops if vm is being destroyed" do
      allow(vm).to receive(:destroy_set?).and_return(true)
      expect { nx.before_run }.to exit({"msg" => "firewall rule is added"})
    end

    it "does nothing if vm is not being destroyed" do
      expect { nx.before_run }.not_to exit
    end
  end

  describe "#update_firewall_rules" do
    let(:fw_rule) {
      instance_double(FirewallRule,
        firewall_id: "fw-id-1", port_range: (22...23), cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
        ip6?: false, protocol: "tcp")
    }

    before do
      allow(vm).to receive(:firewalls).and_return([firewall])
      allow(firewall).to receive(:firewall_rules).and_return([fw_rule])

      # Tag key creation

      # Tag value creation
      tv_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "crm-op-tv", response: {"name" => fw_tag_value_name}, error: nil)

      # Firewall policy rules sync
      empty_policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      allow(nfp_client).to receive_messages(get: empty_policy, add_rule: lro_op)

      # Subnet tag lookup
      subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-subnet-subnetubid1", name: subnet_tag_key_name)
      subnet_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "member", name: subnet_tag_value_name)
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [subnet_tk])
      tv_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [subnet_tv])
      allow(crm_client).to receive_messages(create_tag_key: crm_done_op, get_operation: crm_done_op, create_tag_value: tv_op, list_tag_keys: tk_list, list_tag_values: tv_list)

      # Tag bindings
      empty_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse, tag_bindings: [])
      binding_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      allow(regional_crm_client).to receive_messages(list_tag_bindings: empty_bindings, create_tag_binding: binding_op)
    end

    it "creates per-firewall tag key, tag value, syncs rules, binds tags, and pops" do
      expect(crm_client).to receive(:create_tag_key) do |tag_key|
        expect(tag_key.short_name).to eq("ubicloud-fw-fwubid1")
        expect(tag_key.purpose).to eq("GCE_FIREWALL")
        expect(tag_key.purpose_data["network"]).to include("networks/1234567890")
        crm_done_op
      end

      expect(nfp_client).to receive(:add_rule) do |args|
        rule = args[:firewall_policy_rule_resource]
        expect(rule.direction).to eq("INGRESS")
        expect(rule.action).to eq("allow")
        expect(rule.match.src_ip_ranges).to eq(["0.0.0.0/0"])
        expect(rule.target_secure_tags.first.name).to eq(fw_tag_value_name)
        lro_op
      end

      expect(regional_crm_client).to receive(:create_tag_binding).twice

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "uses fw_tag_data cache on re-entry after nap and skips tag creation" do
      st.stack.first["fw_tag_data"] = {"fwubid1" => "tagValues/cached-tv"}
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)

      # Should NOT call create_tag_key or create_tag_value (already cached).
      expect(crm_client).not_to receive(:create_tag_key)
      expect(crm_client).not_to receive(:create_tag_value)

      # Should still bind tags
      expect(regional_crm_client).to receive(:create_tag_binding).twice

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "syncs empty rules for firewall with no rules and does not bind its tag" do
      allow(firewall).to receive(:firewall_rules).and_return([])

      expect(crm_client).to receive(:create_tag_key)
      expect(crm_client).to receive(:create_tag_value)
      # sync_firewall_rules is called with empty list (cleans up stale rules)
      expect(nfp_client).to receive(:get).and_return(Google::Cloud::Compute::V1::FirewallPolicy.new(rules: []))
      expect(nfp_client).not_to receive(:add_rule)

      # Only subnet tag should be bound (firewall has no rules → not bound)
      expect(regional_crm_client).to receive(:create_tag_binding).once

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "handles multiple firewalls with separate tag keys" do
      firewall2 = instance_double(Firewall, id: "fw-id-2", ubid: "fwubid2")
      fw_rule2 = instance_double(FirewallRule,
        firewall_id: "fw-id-2", port_range: (443...444), cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
        ip6?: false, protocol: "tcp")

      allow(vm).to receive(:firewalls).and_return([firewall, firewall2])
      allow(firewall).to receive(:firewall_rules).and_return([fw_rule])
      allow(firewall2).to receive(:firewall_rules).and_return([fw_rule2])

      # Each firewall gets its own tag key
      created_keys = []
      allow(crm_client).to receive(:create_tag_key) do |tag_key|
        created_keys << tag_key.short_name
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "crm-op", response: {"name" => "tagKeys/#{tag_key.short_name}"}, error: nil)
      end

      # Each firewall gets its own tag value
      allow(crm_client).to receive(:create_tag_value) do |tag_value|
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "crm-op-tv", response: {"name" => "tagValues/#{tag_value.parent}"}, error: nil)
      end

      # Both firewalls get rules synced
      expect(nfp_client).to receive(:add_rule).twice.and_return(lro_op)
      # 2 firewall tags + 1 subnet tag
      expect(regional_crm_client).to receive(:create_tag_binding).exactly(3).times

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
      expect(created_keys).to contain_exactly("ubicloud-fw-fwubid1", "ubicloud-fw-fwubid2")
    end

    it "unbinds stale tags from firewalls no longer attached" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value: "tagValues/old-fw-tv")
      active_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/active-1", tag_value: fw_tag_value_name)

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding, active_binding])

      unbind_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "unbind-op", error: nil)
      expect(regional_crm_client).to receive(:delete_tag_binding).with("tagBindings/stale-1").and_return(unbind_op)
      allow(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      # Should not unbind the active one or the subnet one
      expect(regional_crm_client).not_to receive(:delete_tag_binding).with("tagBindings/active-1")

      # Subnet tag still needs to be bound
      expect(regional_crm_client).to receive(:create_tag_binding).once

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "creates new tag bindings before deleting stale ones" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value: "tagValues/old-fw-tv")

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])

      unbind_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "unbind-op", error: nil)
      allow(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      # Verify all creates happen before any deletes
      call_order = []
      allow(regional_crm_client).to receive(:create_tag_binding) do |binding|
        call_order << :create
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      end
      allow(regional_crm_client).to receive(:delete_tag_binding) do |name|
        call_order << :delete
        unbind_op
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})

      # All creates must precede all deletes
      last_create = call_order.rindex(:create)
      first_delete = call_order.index(:delete)
      expect(last_create).not_to be_nil
      expect(first_delete).not_to be_nil
      expect(last_create).to be < first_delete
    end

    it "retries failed creates after deleting stale bindings when NIC tag limit hit" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value: "tagValues/old-fw-tv")

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])

      unbind_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "unbind-op", error: nil)
      allow(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      # Track per-tag-value create attempts and ordering with deletes.
      # NIC limit 400 persists until stale bindings are freed, so all
      # internal retries (up to 3) in create_tag_binding also fail.
      call_log = []
      stale_deleted = false
      allow(regional_crm_client).to receive(:create_tag_binding) do |binding|
        call_log << [:create, binding.tag_value]
        if binding.tag_value == fw_tag_value_name && !stale_deleted
          raise Google::Apis::ClientError.new("tag limit exceeded", status_code: 400)
        end
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      end
      allow(regional_crm_client).to receive(:delete_tag_binding) do |name|
        stale_deleted = true
        call_log << [:delete, name]
        unbind_op
      end

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})

      # The successful fw create must come after stale delete
      fw_creates = call_log.each_with_index.select { |entry, _| entry == [:create, fw_tag_value_name] }.map(&:last)
      deletes = call_log.each_with_index.select { |entry, _| entry[0] == :delete }.map(&:last)
      expect(fw_creates.length).to be >= 2
      expect(deletes).not_to be_empty
      expect(fw_creates.last).to be > deletes.first
    end

    it "re-raises 400 errors when there are no stale bindings to free" do
      # No stale bindings - all existing are desired
      active_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/active-1", tag_value: fw_tag_value_name)

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [active_binding])

      allow(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      # Subnet tag create fails with 400: no stale bindings to free, so re-raise.
      allow(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("bad request", status_code: 400))

      # Must not attempt to delete any bindings
      expect(regional_crm_client).not_to receive(:delete_tag_binding)

      expect { nx.update_firewall_rules }.to raise_error(Google::Apis::ClientError)
    end

    it "handles subnet tag not found gracefully" do
      no_subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [])
      allow(crm_client).to receive(:list_tag_keys).and_return(no_subnet_tk)

      # Only firewall tag should be bound
      expect(regional_crm_client).to receive(:create_tag_binding).once

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "truncates desired tags and logs when exceeding GCP 10-tag NIC limit" do
      # Create 11 firewalls (each with rules) to exceed the 10-tag limit
      firewalls = (1..11).map { |i| instance_double(Firewall, id: "fw-id-#{i}", ubid: "fwubid#{i}") }
      firewalls.each do |fw|
        rule = instance_double(FirewallRule,
          firewall_id: fw.id, port_range: (22...23), cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          ip6?: false, protocol: "tcp")
        allow(fw).to receive(:firewall_rules).and_return([rule])
      end

      allow(vm).to receive(:firewalls).and_return(firewalls)

      # Each firewall gets its own tag key and value
      allow(crm_client).to receive(:create_tag_key) do |tag_key|
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "crm-op", response: {"name" => "tagKeys/#{tag_key.short_name}"}, error: nil)
      end
      allow(crm_client).to receive(:create_tag_value) do |tag_value|
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "crm-op-tv", response: {"name" => "tagValues/#{tag_value.parent}-active"}, error: nil)
      end

      empty_policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      allow(nfp_client).to receive_messages(get: empty_policy, add_rule: lro_op)

      # 12 desired (11 fw + 1 subnet) → truncated to 10 (9 fw + 1 subnet)
      # Verify subnet tag is preserved by checking it's among the bound tags
      bound_tags = []
      expect(regional_crm_client).to receive(:create_tag_binding).exactly(10).times do |binding|
        bound_tags << binding.tag_value
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      end

      expect(Clog).to receive(:emit).with("GCP NIC tag limit exceeded, truncating to 10", anything)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
      expect(bound_tags).to include(subnet_tag_value_name)
      expect(bound_tags.size).to eq(10)
    end

    it "truncates to 10 without subnet tag when subnet tag is not found" do
      firewalls = (1..11).map { |i| instance_double(Firewall, id: "fw-id-#{i}", ubid: "fwubid#{i}") }
      firewalls.each do |fw|
        rule = instance_double(FirewallRule,
          firewall_id: fw.id, port_range: (22...23), cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"),
          ip6?: false, protocol: "tcp")
        allow(fw).to receive(:firewall_rules).and_return([rule])
      end

      allow(vm).to receive(:firewalls).and_return(firewalls)

      allow(crm_client).to receive(:create_tag_key) do |tag_key|
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "crm-op", response: {"name" => "tagKeys/#{tag_key.short_name}"}, error: nil)
      end
      allow(crm_client).to receive(:create_tag_value) do |tag_value|
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "crm-op-tv", response: {"name" => "tagValues/#{tag_value.parent}-active"}, error: nil)
      end

      # No subnet tag found
      no_subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [])
      allow(crm_client).to receive(:list_tag_keys).and_return(no_subnet_tk)

      empty_policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      allow(nfp_client).to receive_messages(get: empty_policy, add_rule: lro_op)

      # 11 fw tags, no subnet → truncated to 10
      expect(regional_crm_client).to receive(:create_tag_binding).exactly(10).times

      expect(Clog).to receive(:emit).with("GCP NIC tag limit exceeded, truncating to 10", anything)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "skips already-bound tags" do
      existing_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/existing-1", tag_value: fw_tag_value_name)
      subnet_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/existing-2", tag_value: subnet_tag_value_name)

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [existing_binding, subnet_binding])
      allow(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      expect(regional_crm_client).not_to receive(:create_tag_binding)
      expect(regional_crm_client).not_to receive(:delete_tag_binding)

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "handles unbind 404 gracefully" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value: "tagValues/old")

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])
      allow(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      expect(regional_crm_client).to receive(:delete_tag_binding)
        .and_raise(Google::Apis::ClientError.new("not found", status_code: 404))

      # fw + subnet bindings
      expect(regional_crm_client).to receive(:create_tag_binding).twice

      expect { nx.update_firewall_rules }.to exit({"msg" => "firewall rule is added"})
    end

    it "re-raises non-404 errors during stale binding unbind" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value: "tagValues/old")

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])
      allow(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      expect(regional_crm_client).to receive(:delete_tag_binding)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.update_firewall_rules }.to raise_error(Google::Apis::ClientError, /forbidden/)
    end
  end

  describe "ensure_firewall_tag_key" do
    it "creates tag key and returns name from operation response" do
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", response: {"name" => "tagKeys/new-1"}, error: nil)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      result = nx.send(:ensure_firewall_tag_key, firewall)
      expect(result).to eq("tagKeys/new-1")
    end

    it "falls back to lookup when response has no name" do
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", response: nil, error: nil)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-fw-fwubid1", name: "tagKeys/lookup-1")
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [tk])
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      result = nx.send(:ensure_firewall_tag_key, firewall)
      expect(result).to eq("tagKeys/lookup-1")
    end

    it "raises when response has no name and lookup fails" do
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", response: nil, error: nil)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [])
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to raise_error(/created but name not found/)
    end

    it "handles 409 conflict by looking up existing key" do
      expect(crm_client).to receive(:create_tag_key)
        .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))

      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-fw-fwubid1", name: "tagKeys/existing-1")
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [tk])
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      result = nx.send(:ensure_firewall_tag_key, firewall)
      expect(result).to eq("tagKeys/existing-1")
    end

    it "raises on 409 when lookup returns nothing" do
      expect(crm_client).to receive(:create_tag_key)
        .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))

      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: nil)
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to raise_error(/conflict but not found/)
    end

    it "re-raises non-409 client errors" do
      expect(crm_client).to receive(:create_tag_key)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to raise_error(Google::Apis::ClientError)
    end

    it "naps when CRM operation is not done and saves op name in frame" do
      pending_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: false, name: "op-pending")
      expect(crm_client).to receive(:create_tag_key).and_return(pending_op)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to nap(5)
      expect(st.stack.first["pending_tag_key_crm_op"]).to eq("op-pending")
      expect(st.stack.first["pending_tag_key_fw_ubid"]).to eq("fwubid1")
    end

    it "polls pending operation on re-entry and returns name" do
      st.stack.first["pending_tag_key_crm_op"] = "operations/pending-tk"
      st.stack.first["pending_tag_key_fw_ubid"] = "fwubid1"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)

      done_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/pending-tk", response: {"name" => "tagKeys/polled-1"}, error: nil)
      expect(crm_client).to receive(:get_operation).with("operations/pending-tk").and_return(done_op)

      result = nx.send(:ensure_firewall_tag_key, firewall)
      expect(result).to eq("tagKeys/polled-1")
      expect(st.reload.stack.first["pending_tag_key_crm_op"]).to be_nil
    end

    it "naps again when polling pending operation that is still not done" do
      st.stack.first["pending_tag_key_crm_op"] = "operations/still-pending"
      st.stack.first["pending_tag_key_fw_ubid"] = "fwubid1"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)

      still_pending = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: false)
      expect(crm_client).to receive(:get_operation).with("operations/still-pending").and_return(still_pending)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to nap(5)
    end

    it "falls back to lookup when polled op has no name in response" do
      st.stack.first["pending_tag_key_crm_op"] = "operations/no-name"
      st.stack.first["pending_tag_key_fw_ubid"] = "fwubid1"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)

      no_name_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/no-name", response: nil, error: nil)
      expect(crm_client).to receive(:get_operation).with("operations/no-name").and_return(no_name_op)

      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-fw-fwubid1", name: "tagKeys/fallback-poll")
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [tk])
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      result = nx.send(:ensure_firewall_tag_key, firewall)
      expect(result).to eq("tagKeys/fallback-poll")
    end

    it "raises when polled pending op has error" do
      st.stack.first["pending_tag_key_crm_op"] = "operations/tk-error"
      st.stack.first["pending_tag_key_fw_ubid"] = "fwubid1"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)

      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, message: "INTERNAL: server error")
      error_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/tk-error", error:)
      expect(crm_client).to receive(:get_operation).with("operations/tk-error").and_return(error_op)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to raise_error(RuntimeError, /INTERNAL/)
    end

    it "handles ALREADY_EXISTS from CRM LRO by looking up existing key" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, message: "ALREADY_EXISTS: tag key already exists")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-fw-fwubid1", name: "tagKeys/existing-lro-1")
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [tk])
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      result = nx.send(:ensure_firewall_tag_key, firewall)
      expect(result).to eq("tagKeys/existing-lro-1")
    end

    it "raises on ALREADY_EXISTS from LRO when lookup returns nothing" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, message: "ALREADY_EXISTS: tag key already exists")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: nil)
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to raise_error(/conflict but not found/)
    end

    it "re-raises non-ALREADY_EXISTS LRO errors" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, message: "PERMISSION_DENIED: access denied")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to raise_error(RuntimeError, /PERMISSION_DENIED/)
    end

    it "ignores pending op from a different firewall and creates fresh" do
      st.stack.first["pending_tag_key_crm_op"] = "operations/other-fw"
      st.stack.first["pending_tag_key_fw_ubid"] = "fwubid-other"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)

      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", response: {"name" => "tagKeys/fresh-1"}, error: nil)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      result = nx.send(:ensure_firewall_tag_key, firewall)
      expect(result).to eq("tagKeys/fresh-1")
    end
  end

  describe "ensure_tag_value" do
    it "creates tag value and returns name from operation response" do
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", response: {"name" => "tagValues/new-1"}, error: nil)
      expect(crm_client).to receive(:create_tag_value).and_return(op)

      result = nx.send(:ensure_tag_value, "tagKeys/123", "active")
      expect(result).to eq("tagValues/new-1")
    end

    it "falls back to lookup when response has no name" do
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", response: nil, error: nil)
      expect(crm_client).to receive(:create_tag_value).and_return(op)

      tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: "tagValues/lookup-1")
      tv_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [tv])
      expect(crm_client).to receive(:list_tag_values).and_return(tv_list)

      result = nx.send(:ensure_tag_value, "tagKeys/123", "active")
      expect(result).to eq("tagValues/lookup-1")
    end

    it "raises when response has no name and lookup fails" do
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", response: nil, error: nil)
      expect(crm_client).to receive(:create_tag_value).and_return(op)

      tv_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: nil)
      expect(crm_client).to receive(:list_tag_values).and_return(tv_list)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(/created but name not found/)
    end

    it "handles 409 conflict by looking up existing value" do
      expect(crm_client).to receive(:create_tag_value)
        .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))

      tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: "tagValues/existing-1")
      tv_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [tv])
      expect(crm_client).to receive(:list_tag_values).and_return(tv_list)

      result = nx.send(:ensure_tag_value, "tagKeys/123", "active")
      expect(result).to eq("tagValues/existing-1")
    end

    it "raises on 409 when lookup returns nothing" do
      expect(crm_client).to receive(:create_tag_value)
        .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))

      tv_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: nil)
      expect(crm_client).to receive(:list_tag_values).and_return(tv_list)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(/conflict but not found/)
    end

    it "re-raises non-409 client errors" do
      expect(crm_client).to receive(:create_tag_value)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(Google::Apis::ClientError)
    end

    it "handles ALREADY_EXISTS from CRM LRO by looking up existing value" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, message: "ALREADY_EXISTS: tag value already exists")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_value).and_return(op)

      tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: "tagValues/existing-lro-1")
      tv_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [tv])
      expect(crm_client).to receive(:list_tag_values).and_return(tv_list)

      result = nx.send(:ensure_tag_value, "tagKeys/123", "active")
      expect(result).to eq("tagValues/existing-lro-1")
    end

    it "re-raises non-ALREADY_EXISTS LRO errors for tag value" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, message: "PERMISSION_DENIED: access denied")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_value).and_return(op)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(RuntimeError, /PERMISSION_DENIED/)
    end

    it "naps when CRM operation is not done and saves op name in frame" do
      pending_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: false, name: "op-tv-pending")
      expect(crm_client).to receive(:create_tag_value).and_return(pending_op)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to nap(5)
      expect(st.stack.first["pending_tag_value_crm_op"]).to eq("op-tv-pending")
      expect(st.stack.first["pending_tag_value_parent"]).to eq("tagKeys/123")
    end

    it "polls pending operation on re-entry and returns name" do
      st.stack.first["pending_tag_value_crm_op"] = "operations/pending-tv"
      st.stack.first["pending_tag_value_parent"] = "tagKeys/123"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)

      done_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/pending-tv", response: {"name" => "tagValues/polled-1"}, error: nil)
      expect(crm_client).to receive(:get_operation).with("operations/pending-tv").and_return(done_op)

      result = nx.send(:ensure_tag_value, "tagKeys/123", "active")
      expect(result).to eq("tagValues/polled-1")
      expect(st.reload.stack.first["pending_tag_value_crm_op"]).to be_nil
    end

    it "naps again when polling pending tag value op that is still not done" do
      st.stack.first["pending_tag_value_crm_op"] = "operations/tv-still-pending"
      st.stack.first["pending_tag_value_parent"] = "tagKeys/123"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)

      still_pending = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: false)
      expect(crm_client).to receive(:get_operation).with("operations/tv-still-pending").and_return(still_pending)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to nap(5)
    end

    it "falls back to lookup when polled tag value op has no name in response" do
      st.stack.first["pending_tag_value_crm_op"] = "operations/tv-no-name"
      st.stack.first["pending_tag_value_parent"] = "tagKeys/123"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)

      no_name_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/tv-no-name", response: nil, error: nil)
      expect(crm_client).to receive(:get_operation).with("operations/tv-no-name").and_return(no_name_op)

      tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: "tagValues/fallback-poll")
      tv_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [tv])
      expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/123").and_return(tv_list)

      result = nx.send(:ensure_tag_value, "tagKeys/123", "active")
      expect(result).to eq("tagValues/fallback-poll")
    end

    it "raises when polled pending tag value op has error" do
      st.stack.first["pending_tag_value_crm_op"] = "operations/tv-error"
      st.stack.first["pending_tag_value_parent"] = "tagKeys/123"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)

      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, message: "INTERNAL: server error")
      error_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/tv-error", error:)
      expect(crm_client).to receive(:get_operation).with("operations/tv-error").and_return(error_op)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(RuntimeError, /INTERNAL/)
    end

    it "ignores pending op from a different parent and creates fresh" do
      st.stack.first["pending_tag_value_crm_op"] = "operations/other-parent"
      st.stack.first["pending_tag_value_parent"] = "tagKeys/999"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)

      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", response: {"name" => "tagValues/fresh-1"}, error: nil)
      expect(crm_client).to receive(:create_tag_value).and_return(op)

      result = nx.send(:ensure_tag_value, "tagKeys/123", "active")
      expect(result).to eq("tagValues/fresh-1")
    end
  end

  describe "sync_tag_policy_rules" do
    let(:tag_value) { "tagValues/test-tv" }

    it "creates new rules when no existing rules" do
      empty_policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      expect(nfp_client).to receive(:get).and_return(empty_policy)

      desired = [{
        direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: [tag_value],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }]

      expect(nfp_client).to receive(:add_rule) do |args|
        rule = args[:firewall_policy_rule_resource]
        expect(rule.priority).to eq(10000)
        expect(rule.direction).to eq("INGRESS")
        expect(rule.match.src_ip_ranges).to eq(["0.0.0.0/0"])
        expect(rule.target_secure_tags.first.name).to eq(tag_value)
        lro_op
      end

      nx.send(:sync_tag_policy_rules, desired, tag_value)
    end

    it "skips matching existing rules" do
      existing_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10000,
        direction: "INGRESS",
        action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: ["0.0.0.0/0"],
          layer4_configs: [
            Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(
              ip_protocol: "tcp", ports: ["22"],
            ),
          ],
        ),
        target_secure_tags: [
          Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: tag_value),
        ],
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [existing_rule])
      expect(nfp_client).to receive(:get).and_return(policy)

      desired = [{
        direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: [tag_value],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }]

      expect(nfp_client).not_to receive(:add_rule)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:sync_tag_policy_rules, desired, tag_value)
    end

    it "deletes unmatched existing rules" do
      stale_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10000,
        direction: "INGRESS",
        action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: ["10.0.0.0/8"],
          layer4_configs: [
            Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "tcp", ports: ["80"]),
          ],
        ),
        target_secure_tags: [
          Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: tag_value),
        ],
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [stale_rule])
      expect(nfp_client).to receive(:get).and_return(policy)

      expect(nfp_client).to receive(:remove_rule).with(hash_including(priority: 10000)).and_return(lro_op)

      nx.send(:sync_tag_policy_rules, [], tag_value)
    end

    it "skips priorities already in use when creating rules" do
      occupied_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10000,
        direction: "INGRESS",
        action: "deny",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: ["192.168.0.0/16"],
        ),
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [occupied_rule])
      expect(nfp_client).to receive(:get).and_return(policy)

      desired = [{
        direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: [tag_value],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }]

      expect(nfp_client).to receive(:add_rule) do |args|
        expect(args[:firewall_policy_rule_resource].priority).to eq(10001)
        lro_op
      end

      nx.send(:sync_tag_policy_rules, desired, tag_value)
    end

    it "does not count rules being deleted as used priorities" do
      # An existing rule for our tag at priority 10000 that doesn't match desired
      stale_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10000,
        direction: "INGRESS",
        action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: ["10.0.0.0/8"],
          layer4_configs: [
            Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "tcp", ports: ["80"]),
          ],
        ),
        target_secure_tags: [
          Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: tag_value),
        ],
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [stale_rule])
      expect(nfp_client).to receive(:get).and_return(policy)

      desired = [{
        direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: [tag_value],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }]

      expect(nfp_client).to receive(:remove_rule).with(hash_including(priority: 10000)).and_return(lro_op)
      expect(nfp_client).to receive(:add_rule) do |args|
        # Should reuse priority 10000 since the stale rule is being deleted
        expect(args[:firewall_policy_rule_resource].priority).to eq(10000)
        lro_op
      end

      nx.send(:sync_tag_policy_rules, desired, tag_value)
    end

    it "ignores rules for other tag values" do
      other_tag_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10000,
        direction: "INGRESS",
        action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: ["0.0.0.0/0"],
          layer4_configs: [
            Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "tcp", ports: ["22"]),
          ],
        ),
        target_secure_tags: [
          Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: "tagValues/other-tv"),
        ],
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [other_tag_rule])
      expect(nfp_client).to receive(:get).and_return(policy)

      # Should not delete the other tag's rule
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:sync_tag_policy_rules, [], tag_value)
    end
  end

  describe "create_tag_policy_rule" do
    it "creates rule via add_rule" do
      desired = {
        priority: 10000,
        direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: ["tagValues/tv-1"],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }

      expect(nfp_client).to receive(:add_rule).and_return(lro_op)
      nx.send(:create_tag_policy_rule, desired)
    end

    it "handles AlreadyExistsError by retrying with new priority" do
      desired = {
        priority: 10000,
        direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: ["tagValues/tv-1"],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }

      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(
        rules: [Google::Cloud::Compute::V1::FirewallPolicyRule.new(priority: 10000)],
      )

      expect(nfp_client).to receive(:add_rule).ordered
        .and_raise(Google::Cloud::AlreadyExistsError.new("exists"))
      expect(Clog).to receive(:emit).with("GCP firewall priority collision, retrying with new priority", anything)
      expect(nfp_client).to receive(:get).with(project: "test-gcp-project", firewall_policy: vpc_name).and_return(policy)
      expect(nfp_client).to receive(:add_rule).ordered.and_return(lro_op)

      nx.send(:create_tag_policy_rule, desired)
      expect(desired[:priority]).to eq(10001)
    end

    it "handles InvalidArgumentError with 'same priorities' by retrying with new priority" do
      desired = {
        priority: 10000,
        direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: ["tagValues/tv-1"],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }

      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(
        rules: [Google::Cloud::Compute::V1::FirewallPolicyRule.new(priority: 10000)],
      )

      expect(nfp_client).to receive(:add_rule).ordered
        .and_raise(Google::Cloud::InvalidArgumentError.new("same priorities"))
      expect(Clog).to receive(:emit).with("GCP firewall priority collision, retrying with new priority", anything)
      expect(nfp_client).to receive(:get).with(project: "test-gcp-project", firewall_policy: vpc_name).and_return(policy)
      expect(nfp_client).to receive(:add_rule).ordered.and_return(lro_op)

      nx.send(:create_tag_policy_rule, desired)
      expect(desired[:priority]).to eq(10001)
    end

    it "re-raises InvalidArgumentError not about priorities" do
      desired = {
        priority: 10000,
        direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: ["tagValues/tv-1"],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }

      expect(nfp_client).to receive(:add_rule)
        .and_raise(Google::Cloud::InvalidArgumentError.new("invalid field"))

      expect { nx.send(:create_tag_policy_rule, desired) }.to raise_error(Google::Cloud::InvalidArgumentError, /invalid field/)
    end

    it "raises after 5 retries on persistent priority collisions" do
      desired = {
        priority: 10000,
        direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: ["tagValues/tv-1"],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }

      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(
        rules: (10000..10010).map { |p| Google::Cloud::Compute::V1::FirewallPolicyRule.new(priority: p) },
      )

      expect(nfp_client).to receive(:add_rule).exactly(6).times
        .and_raise(Google::Cloud::AlreadyExistsError.new("exists"))
      expect(Clog).to receive(:emit).with("GCP firewall priority collision, retrying with new priority", anything).exactly(5).times
      expect(nfp_client).to receive(:get).with(project: "test-gcp-project", firewall_policy: vpc_name).exactly(5).times.and_return(policy)

      expect { nx.send(:create_tag_policy_rule, desired) }.to raise_error(Google::Cloud::AlreadyExistsError)
    end
  end

  describe "delete_policy_rule" do
    it "removes the rule" do
      expect(nfp_client).to receive(:remove_rule)
        .with(project: "test-gcp-project", firewall_policy: vpc_name, priority: 10000)
        .and_return(lro_op)

      nx.send(:delete_policy_rule, 10000)
    end

    it "handles NotFoundError" do
      expect(nfp_client).to receive(:remove_rule)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect { nx.send(:delete_policy_rule, 10000) }.not_to raise_error
    end

    it "handles InvalidArgumentError" do
      expect(nfp_client).to receive(:remove_rule)
        .and_raise(Google::Cloud::InvalidArgumentError.new("invalid"))
      expect { nx.send(:delete_policy_rule, 10000) }.not_to raise_error
    end
  end

  describe "create_tag_binding" do
    it "creates a tag binding via regional CRM" do
      binding_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      expect(regional_crm_client).to receive(:create_tag_binding).and_return(binding_op)

      nx.send(:create_tag_binding, "//compute.googleapis.com/projects/123/zones/us-central1-a/instances/456", "tagValues/tv-1")
    end

    it "handles 409 conflict (already bound)" do
      expect(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))

      expect { nx.send(:create_tag_binding, "//compute.googleapis.com/...", "tagValues/tv-1") }.not_to raise_error
    end

    it "re-raises non-409 non-400 errors" do
      expect(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.send(:create_tag_binding, "//compute.googleapis.com/...", "tagValues/tv-1") }.to raise_error(Google::Apis::ClientError)
    end

    it "re-raises 400 errors" do
      allow(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("bad request", status_code: 400))

      expect { nx.send(:create_tag_binding, "//compute.googleapis.com/...", "tagValues/tv-1") }.to raise_error(Google::Apis::ClientError)
    end
  end

  describe "vm_instance_resource_name" do
    it "returns the resource name with project number and instance ID" do
      result = nx.send(:vm_instance_resource_name)
      expect(result).to eq("//compute.googleapis.com/projects/73189733048/zones/us-central1-a/instances/9876543210")
    end
  end

  describe "find_firewall" do
    it "delegates to Firewall[]" do
      expect(nx.send(:find_firewall, Firewall.generate_ubid.to_s)).to be_nil
    end
  end

  describe "cleanup_orphaned_firewall_rules" do
    let(:orphan_fw_ubid) { "orphanfwubid1" }
    let(:orphan_tag_key_name) { "tagKeys/orphan-123" }
    let(:orphan_tag_value_name) { "tagValues/orphan-tv-1" }
    let(:vpc_purpose_data) { {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/1234567890"} }

    let(:vm_firewall_dataset) { instance_double(Sequel::Dataset) }

    before do
      allow(vm).to receive(:firewalls).and_return([firewall])
      # Default: orphaned firewalls have no VM associations either
      allow(DB).to receive(:[]).and_call_original
      allow(DB).to receive(:[]).with(:firewalls_vms).and_return(vm_firewall_dataset)
      allow(vm_firewall_dataset).to receive(:where).and_return(instance_double(Sequel::Dataset, any?: false))
    end

    it "deletes policy rules, tag value, and tag key for firewalls with no subnets" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)
      active_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-fwubid1", name: fw_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk, active_tk]))

      orphan_fw = instance_double(Firewall, ubid: orphan_fw_ubid, private_subnets: [], id: "orphan-fw-id")
      allow(nx).to receive(:find_firewall).with(orphan_fw_ubid).and_return(orphan_fw)

      orphan_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: orphan_tag_value_name)
      allow(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [orphan_tv]))

      orphan_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10005,
        action: "allow",
        target_secure_tags: [Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: orphan_tag_value_name)],
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [orphan_rule])
      allow(nfp_client).to receive(:get).and_return(policy)

      expect(nfp_client).to receive(:remove_rule).with(hash_including(priority: 10005)).and_return(lro_op)
      expect(crm_client).to receive(:delete_tag_value).with(orphan_tag_value_name).and_return(crm_done_op)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name).and_return(crm_done_op)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "deletes policy rules, tag value, and tag key for deleted firewalls (not found in DB)" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk]))

      allow(nx).to receive(:find_firewall).with(orphan_fw_ubid).and_return(nil)

      orphan_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: orphan_tag_value_name)
      allow(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [orphan_tv]))

      orphan_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10010,
        action: "allow",
        target_secure_tags: [Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: orphan_tag_value_name)],
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [orphan_rule])
      allow(nfp_client).to receive(:get).and_return(policy)

      expect(nfp_client).to receive(:remove_rule).with(hash_including(priority: 10010)).and_return(lro_op)
      expect(crm_client).to receive(:delete_tag_value).with(orphan_tag_value_name).and_return(crm_done_op)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name).and_return(crm_done_op)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips firewalls still attached to subnets" do
      attached_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [attached_tk]))

      attached_fw = instance_double(Firewall, ubid: orphan_fw_ubid, private_subnets: [ps])
      allow(nx).to receive(:find_firewall).with(orphan_fw_ubid).and_return(attached_fw)

      expect(nfp_client).not_to receive(:get)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips firewalls attached directly to VMs (not through subnets)" do
      vm_fw_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [vm_fw_tk]))

      vm_fw = instance_double(Firewall, ubid: orphan_fw_ubid, private_subnets: [], id: "vm-fw-id")
      allow(nx).to receive(:find_firewall).with(orphan_fw_ubid).and_return(vm_fw)
      allow(vm_firewall_dataset).to receive(:where).with(firewall_id: "vm-fw-id").and_return(instance_double(Sequel::Dataset, any?: true))

      expect(nfp_client).not_to receive(:get)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips active firewalls (attached to this VM)" do
      # Only active firewall tag key present. Should be skipped entirely.
      active_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-fwubid1", name: fw_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [active_tk]))

      expect(nfp_client).not_to receive(:get)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips non-GCE_FIREWALL tag keys" do
      non_fw_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-someubid", name: "tagKeys/other-1", purpose: nil)

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [non_fw_tk]))

      expect(nfp_client).not_to receive(:get)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips tag keys without matching short_name prefix" do
      subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-subnet-subnetubid1", name: "tagKeys/subnet-1", purpose: "GCE_FIREWALL")

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [subnet_tk]))

      expect(nfp_client).not_to receive(:get)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "returns early when no tag keys exist" do
      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: nil))

      expect(nfp_client).not_to receive(:get)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips tag keys from other VPCs" do
      other_vpc_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL",
        purpose_data: {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/9999999999"})

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [other_vpc_tk]))

      expect(nfp_client).not_to receive(:get)
      expect(crm_client).not_to receive(:delete_tag_key)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips tag keys with nil purpose_data" do
      nil_pd_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL",
        purpose_data: nil)

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [nil_pd_tk]))

      expect(nfp_client).not_to receive(:get)
      expect(crm_client).not_to receive(:delete_tag_key)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "deletes tag key even when no tag value exists" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk]))
      allow(nx).to receive(:find_firewall).with(orphan_fw_ubid).and_return(nil)

      allow(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: nil))

      expect(nfp_client).not_to receive(:get)
      expect(nfp_client).not_to receive(:remove_rule)
      expect(crm_client).not_to receive(:delete_tag_value)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name).and_return(crm_done_op)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips non-allow rules but still deletes tag value and key" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk]))
      allow(nx).to receive(:find_firewall).with(orphan_fw_ubid).and_return(nil)

      orphan_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: orphan_tag_value_name)
      allow(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [orphan_tv]))

      deny_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10005,
        action: "deny",
        target_secure_tags: [Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: orphan_tag_value_name)],
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [deny_rule])
      allow(nfp_client).to receive(:get).and_return(policy)

      expect(nfp_client).not_to receive(:remove_rule)
      expect(crm_client).to receive(:delete_tag_value).with(orphan_tag_value_name).and_return(crm_done_op)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name).and_return(crm_done_op)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips allow rules whose tags do not match the orphan tag value" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk]))
      allow(nx).to receive(:find_firewall).with(orphan_fw_ubid).and_return(nil)

      orphan_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: orphan_tag_value_name)
      allow(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [orphan_tv]))

      unrelated_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10005,
        action: "allow",
        target_secure_tags: [Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: "tagValues/other-tv")],
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [unrelated_rule])
      allow(nfp_client).to receive(:get).and_return(policy)

      expect(nfp_client).not_to receive(:remove_rule)
      expect(crm_client).to receive(:delete_tag_value).with(orphan_tag_value_name).and_return(crm_done_op)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name).and_return(crm_done_op)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "propagates errors from per-orphan cleanup" do
      orphan_tk1 = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk1]))
      allow(nx).to receive(:find_firewall).and_return(nil)

      allow(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.send(:cleanup_orphaned_firewall_rules) }.to raise_error(Google::Apis::ClientError, /forbidden/)
    end

    it "propagates Google::Cloud::Error from list_tag_keys" do
      allow(vm).to receive(:firewalls).and_return([firewall])
      allow(crm_client).to receive(:list_tag_keys)
        .and_raise(Google::Cloud::Error.new("error"))

      expect { nx.send(:cleanup_orphaned_firewall_rules) }.to raise_error(Google::Cloud::Error)
    end

    it "propagates RuntimeError from list_tag_keys during orphan cleanup" do
      allow(vm).to receive(:firewalls).and_return([firewall])
      allow(crm_client).to receive(:list_tag_keys)
        .and_raise(RuntimeError.new("CRM operation op-1 failed: PERMISSION_DENIED"))

      expect { nx.send(:cleanup_orphaned_firewall_rules) }.to raise_error(RuntimeError, /PERMISSION_DENIED/)
    end

    it "propagates RuntimeError from delete_tag_key during orphan cleanup" do
      orphan_tk1 = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      allow(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk1]))
      allow(nx).to receive(:find_firewall).and_return(nil)

      allow(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: nil))
      allow(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name)
        .and_raise(RuntimeError.new("CRM operation op-1 failed: Cannot delete tag key still attached to resources"))

      expect { nx.send(:cleanup_orphaned_firewall_rules) }.to raise_error(RuntimeError, /Cannot delete tag key/)
    end
  end

  describe "build_tag_based_policy_rules" do
    it "groups rules by CIDR" do
      rules = [
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: (22...23), protocol: "tcp", ip6?: false),
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: (443...444), protocol: "tcp", ip6?: false),
      ]

      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(1)
      expect(result.first[:source_ranges]).to eq(["0.0.0.0/0"])
      expect(result.first[:layer4_configs].first[:ports]).to contain_exactly("22", "443")
    end

    it "creates separate rules for different CIDRs" do
      rules = [
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: (22...23), protocol: "tcp", ip6?: false),
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("10.0.0.0/8"), port_range: (5432...5433), protocol: "tcp", ip6?: false),
      ]

      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(2)
    end

    it "returns empty array for empty rules" do
      result = nx.send(:build_tag_based_policy_rules, [], tag_value_name: "tagValues/tv-1")
      expect(result).to eq([])
    end

    it "groups by protocol within a CIDR" do
      rules = [
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: (22...23), protocol: "tcp", ip6?: false),
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: (53...54), protocol: "udp", ip6?: false),
      ]

      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(1)
      expect(result.first[:layer4_configs].length).to eq(2)
      protos = result.first[:layer4_configs].map { |c| c[:ip_protocol] }
      expect(protos).to contain_exactly("tcp", "udp")
    end

    it "formats port ranges correctly" do
      rules = [
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: (80...9999), protocol: "tcp", ip6?: false),
      ]

      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.first[:layer4_configs].first[:ports]).to eq(["80-9998"])
    end

    it "formats single-port ranges as single number" do
      rules = [
        instance_double(FirewallRule, cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: (5432...5433), protocol: "tcp", ip6?: false),
      ]

      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.first[:layer4_configs].first[:ports]).to eq(["5432"])
    end
  end

  describe "tag_policy_rule_matches?" do
    let(:tag_value) { "tagValues/test-tv" }

    def make_rule(direction: "INGRESS", action: "allow", src_ranges: ["0.0.0.0/0"], tags: [tag_value], l4: [{proto: "tcp", ports: ["22"]}])
      Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction:,
        action:,
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: src_ranges,
          layer4_configs: l4.map { |c|
            Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(
              ip_protocol: c[:proto], ports: c[:ports],
            )
          },
        ),
        target_secure_tags: tags.map { |t|
          Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: t)
        },
      )
    end

    def make_desired(source_ranges: ["0.0.0.0/0"], tags: [tag_value], l4: [{ip_protocol: "tcp", ports: ["22"]}])
      {
        direction: "INGRESS",
        source_ranges:,
        target_secure_tags: tags,
        layer4_configs: l4,
      }
    end

    it "returns true for matching rules" do
      expect(nx.send(:tag_policy_rule_matches?, make_rule, make_desired)).to be true
    end

    it "returns false for nil match" do
      rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(direction: "INGRESS", action: "allow")
      expect(nx.send(:tag_policy_rule_matches?, rule, make_desired)).to be false
    end

    it "returns false for wrong direction" do
      expect(nx.send(:tag_policy_rule_matches?, make_rule(direction: "EGRESS"), make_desired)).to be false
    end

    it "returns false for wrong action" do
      expect(nx.send(:tag_policy_rule_matches?, make_rule(action: "deny"), make_desired)).to be false
    end

    it "returns false for different source ranges" do
      expect(nx.send(:tag_policy_rule_matches?, make_rule(src_ranges: ["10.0.0.0/8"]), make_desired)).to be false
    end

    it "returns false for different tags" do
      expect(nx.send(:tag_policy_rule_matches?, make_rule(tags: ["tagValues/other"]), make_desired)).to be false
    end

    it "returns false for different layer4 count" do
      two_l4_rule = make_rule(l4: [{proto: "tcp", ports: ["22"]}, {proto: "udp", ports: ["53"]}])
      expect(nx.send(:tag_policy_rule_matches?, two_l4_rule, make_desired)).to be false
    end

    it "returns false for different protocol" do
      expect(nx.send(:tag_policy_rule_matches?, make_rule(l4: [{proto: "udp", ports: ["22"]}]), make_desired)).to be false
    end

    it "returns false for different ports" do
      expect(nx.send(:tag_policy_rule_matches?, make_rule(l4: [{proto: "tcp", ports: ["443"]}]), make_desired)).to be false
    end

    it "matches with nil ports" do
      rule = make_rule(l4: [{proto: "all", ports: nil}])
      desired = make_desired(l4: [{ip_protocol: "all", ports: []}])
      expect(nx.send(:tag_policy_rule_matches?, rule, desired)).to be true
    end
  end

  describe "lookup_subnet_tag_value" do
    it "returns tag value name when subnet tag exists" do
      subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-subnet-subnetubid1", name: "tagKeys/subnet-1")
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [subnet_tk])
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      subnet_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "member", name: "tagValues/subnet-tv-1")
      tv_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [subnet_tv])
      expect(crm_client).to receive(:list_tag_values).and_return(tv_list)

      result = nx.send(:lookup_subnet_tag_value)
      expect(result).to eq("tagValues/subnet-tv-1")
    end

    it "returns nil when subnet tag key not found" do
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [])
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      result = nx.send(:lookup_subnet_tag_value)
      expect(result).to be_nil
    end

    it "returns nil when subnet tag value not found" do
      subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-subnet-subnetubid1", name: "tagKeys/subnet-1")
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [subnet_tk])
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      tv_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: nil)
      expect(crm_client).to receive(:list_tag_values).and_return(tv_list)

      result = nx.send(:lookup_subnet_tag_value)
      expect(result).to be_nil
    end
  end

  describe "helper methods" do
    it "reads zone suffix from strand stack" do
      st.stack.first["gcp_zone_suffix"] = "c"
      expect(nx.send(:gcp_zone)).to eq("us-central1-c")
    end

    it "defaults zone suffix to 'a'" do
      expect(nx.send(:gcp_zone)).to eq("us-central1-a")
    end

    it "finds zone suffix in parent frame" do
      st.stack.unshift({})
      st.stack.last["gcp_zone_suffix"] = "b"
      expect(nx.send(:gcp_zone)).to eq("us-central1-b")
    end

    it "returns gcp_region from location" do
      expect(nx.send(:gcp_region)).to eq("us-central1")
    end

    it "returns firewall_policy_name as vpc_name" do
      expect(nx.send(:firewall_policy_name)).to eq(vpc_name)
    end

    it "returns gcp_network_self_link_with_id from gcp_vpc" do
      result = nx.send(:gcp_network_self_link_with_id)
      expect(result).to eq("https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/1234567890")
    end

    it "returns gcp_project_number from CRM" do
      result = nx.send(:gcp_project_number)
      expect(result).to eq("73189733048")
    end
  end

  describe "sync_firewall_rules" do
    it "partitions IPv4 and IPv6 rules and syncs" do
      ipv4_rule = instance_double(FirewallRule,
        cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: (22...23), protocol: "tcp", ip6?: false)
      ipv6_rule = instance_double(FirewallRule,
        cidr: NetAddr::IPv6Net.parse("::/0"), port_range: (22...23), protocol: "tcp", ip6?: true)

      empty_policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      expect(nfp_client).to receive(:get).and_return(empty_policy)

      # Should create two rules: one for IPv4, one for IPv6
      expect(nfp_client).to receive(:add_rule).twice.and_return(lro_op)

      nx.send(:sync_firewall_rules, [ipv4_rule, ipv6_rule], "tagValues/tv-1")
    end

    it "treats nil port_range as all ports (no ports field in layer4 config)" do
      rule = instance_double(FirewallRule,
        cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: nil, protocol: "tcp", ip6?: false)

      empty_policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      expect(nfp_client).to receive(:get).and_return(empty_policy)

      expect(nfp_client).to receive(:add_rule) do |args|
        l4 = args[:firewall_policy_rule_resource].match.layer4_configs.first
        expect(l4.ip_protocol).to eq("tcp")
        expect(l4.ports).to be_empty
        lro_op
      end

      nx.send(:sync_firewall_rules, [rule], "tagValues/tv-1")
    end

    it "nil port_range dominates when mixed with specific ports in the same protocol group" do
      all_ports_rule = instance_double(FirewallRule,
        cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: nil, protocol: "tcp", ip6?: false)
      specific_rule = instance_double(FirewallRule,
        cidr: NetAddr::IPv4Net.parse("0.0.0.0/0"), port_range: 22..23, protocol: "tcp", ip6?: false)

      empty_policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      expect(nfp_client).to receive(:get).and_return(empty_policy)

      expect(nfp_client).to receive(:add_rule) do |args|
        l4 = args[:firewall_policy_rule_resource].match.layer4_configs.first
        expect(l4.ip_protocol).to eq("tcp")
        expect(l4.ports).to be_empty
        lro_op
      end

      nx.send(:sync_firewall_rules, [all_ports_rule, specific_rule], "tagValues/tv-1")
    end
  end
end
