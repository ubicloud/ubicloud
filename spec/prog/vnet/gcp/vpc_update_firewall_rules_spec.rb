# frozen_string_literal: true

require "google/cloud/compute/v1"
require "google/apis/cloudresourcemanager_v3"

RSpec.describe Prog::Vnet::Gcp::VpcUpdateFirewallRules do
  subject(:nx) { described_class.new(st) }

  let(:v1) { Google::Cloud::Compute::V1 }
  let(:project) { Project.create(name: "test-prj") }

  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp", project_id: project.id,
      display_name: "gcp-us-central1", ui_name: "GCP US Central 1", visible: true)
  }

  let(:location_credential) {
    LocationCredentialGcp.create_with_id(location,
      project_id: "test-gcp-project",
      service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
      credentials_json: "{}")
  }

  let(:vpc_name) { "ubicloud-#{project.ubid}-#{location.ubid}" }

  let(:gcp_vpc) {
    location_credential
    vpc = GcpVpc.create(
      project_id: project.id,
      location_id: location.id,
      name: vpc_name,
      network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/1234567890",
    )
    Strand.create_with_id(vpc, prog: "Vnet::Gcp::VpcNexus", label: "wait")
    vpc
  }

  let(:ps) {
    private_subnet = PrivateSubnet.create(
      name: "ps-1", location_id: location.id, project_id: project.id,
      net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", state: "waiting",
    )
    DB[:private_subnet_gcp_vpc].insert(private_subnet_id: private_subnet.id, gcp_vpc_id: gcp_vpc.id)
    private_subnet
  }

  let(:firewall) {
    fw = Firewall.create(name: "fw-1", location_id: location.id, project_id: project.id)
    fw.associate_with_private_subnet(ps, apply_firewalls: false)
    fw
  }

  # VpcUpdateFirewallRules runs as a child of Vnet::Gcp::VpcNexus (pushed from
  # vpc_nexus.rb#update_firewall_rules). Production has a two-frame stack:
  #   stack[0] = VpcUpdateFirewallRules child frame (subject_id + link)
  #   stack[-1] = Vnet::Gcp::VpcNexus parent frame
  let(:st) {
    child_frame = {"subject_id" => gcp_vpc.id, "link" => ["Vnet::Gcp::VpcNexus", "update_firewall_rules"]}
    gcp_vpc.strand.update(
      prog: "Vnet::Gcp::VpcUpdateFirewallRules",
      label: "update_firewall_rules",
      stack: Sequel.pg_jsonb_wrap([child_frame] + gcp_vpc.strand.stack),
    )
  }

  let(:nfp_client) { instance_double(v1::NetworkFirewallPolicies::Rest::Client) }
  let(:crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }
  let(:global_ops_client) { instance_double(v1::GlobalOperations::Rest::Client) }

  let(:lro_op) { instance_double(Gapic::GenericLRO::Operation, name: "op-12345") }
  let(:done_compute_op) { v1::Operation.new(name: "op-12345", status: :DONE) }

  let(:fw_tag_key_name) { "tagKeys/fw-123" }
  let(:fw_tag_value_name) { "tagValues/fw-tv-1" }

  let(:crm_done_op) {
    instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
      done?: true, name: "crm-op-1", response: {"name" => "tagKeys/created-1"}, error: nil)
  }

  before do
    allow(nx.send(:credential)).to receive_messages(
      network_firewall_policies_client: nfp_client,
      crm_client:,
      global_operations_client: global_ops_client,
    )
    stub_fetch_all_via_list(crm_client)
  end

  describe "#before_run" do
    it "pops if the VPC is being destroyed" do
      gcp_vpc.incr_destroy
      expect { nx.before_run }.to hop("update_firewall_rules", "Vnet::Gcp::VpcNexus")
    end

    it "does nothing if the VPC is not being destroyed" do
      expect { nx.before_run }.not_to exit
    end
  end

  describe "#update_firewall_rules" do
    let(:fw_rule) {
      firewall.firewall_rules.each(&:destroy)
      FirewallRule.create(firewall_id: firewall.id,
        cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23))
    }

    before do
      fw_rule
      tv_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "crm-op-tv", response: {"name" => fw_tag_value_name}, error: nil)

      empty_policy = v1::FirewallPolicy.new(rules: [])
      allow(nfp_client).to receive_messages(get: empty_policy, add_rule: lro_op)

      empty_tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [], next_page_token: nil)
      allow(crm_client).to receive_messages(
        create_tag_key: crm_done_op,
        get_operation: crm_done_op,
        create_tag_value: tv_op,
        list_tag_keys: empty_tk_list,
      )
    end

    it "creates tag key/value, adds one packed rule, and naps on its LRO" do
      allow(Clog).to receive(:emit).and_call_original
      expect(crm_client).to receive(:create_tag_key) do |tag_key|
        expect(tag_key.short_name).to eq("ubicloud-fw-#{firewall.ubid}")
        expect(tag_key.purpose).to eq("GCE_FIREWALL")
        expect(tag_key.purpose_data["network"]).to include("networks/1234567890")
        crm_done_op
      end

      expect(nfp_client).to receive(:add_rule) do |args|
        rule = args[:firewall_policy_rule_resource]
        expect(rule.direction).to eq("INGRESS")
        expect(rule.match.src_ip_ranges).to eq(["0.0.0.0/0"])
        expect(rule.target_secure_tags.first.name).to eq(fw_tag_value_name)
        lro_op
      end

      expect(Clog).to receive(:emit).with("GCP tag key created", hash_including(gcp_tag_key_created: "tagKeys/created-1")).and_call_original
      expect(Clog).to receive(:emit).with("GCP tag value created", hash_including(gcp_tag_value_created: fw_tag_value_name)).and_call_original

      expect { nx.update_firewall_rules }.to nap(5)
      expect(st.stack.first["policy_rule_ops"]).to eq(["op-12345"])
      expect(st.stack.first["fw_tag_data"]).to eq({firewall.ubid => fw_tag_value_name})
    end

    it "pops once the policy is converged, polling the pending mutation op first" do
      refresh_frame(nx, new_values: {
        "fw_tag_data" => {firewall.ubid => fw_tag_value_name},
        "policy_rule_ops" => ["op-12345"],
      })
      expect(global_ops_client).to receive(:get)
        .with(project: "test-gcp-project", operation: "op-12345").and_return(done_compute_op)

      converged_rule = v1::FirewallPolicyRule.new(
        priority: 10000, direction: "INGRESS", action: "allow",
        match: v1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: ["0.0.0.0/0"],
          layer4_configs: [v1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "tcp", ports: ["22"])],
        ),
        target_secure_tags: [v1::FirewallPolicyRuleSecureTag.new(name: fw_tag_value_name)],
      )
      expect(nfp_client).to receive(:get).and_return(v1::FirewallPolicy.new(rules: [converged_rule]))
      expect(nfp_client).not_to receive(:add_rule)

      expect { nx.update_firewall_rules }.to hop("update_firewall_rules", "Vnet::Gcp::VpcNexus")
      expect(st.stack.first["policy_rule_ops"]).to be_nil
    end

    it "naps while the pending mutation op is still running" do
      refresh_frame(nx, new_values: {
        "fw_tag_data" => {firewall.ubid => fw_tag_value_name},
        "policy_rule_ops" => ["op-12345"],
      })
      expect(global_ops_client).to receive(:get)
        .and_return(v1::Operation.new(name: "op-12345", status: :RUNNING))
      expect(nfp_client).not_to receive(:get)

      expect { nx.update_firewall_rules }.to nap(5)
    end

    it "logs a failed mutation op and rediffs instead of raising" do
      refresh_frame(nx, new_values: {
        "fw_tag_data" => {firewall.ubid => fw_tag_value_name},
        "policy_rule_ops" => ["op-12345"],
      })
      failed_op = v1::Operation.new(name: "op-12345", status: :DONE, http_error_status_code: 400)
      expect(global_ops_client).to receive(:get).and_return(failed_op)
      allow(Clog).to receive(:emit).and_call_original
      expect(Clog).to receive(:emit).with("GCP firewall policy mutation failed, rediffing", anything).and_call_original

      expect(nfp_client).to receive(:get).and_return(v1::FirewallPolicy.new(rules: []))
      expect(nfp_client).to receive(:add_rule).and_return(lro_op)

      expect { nx.update_firewall_rules }.to nap(5)
    end

    it "converges firewalls attached to subnets and VMs in the VPC one mutation at a time" do
      # direct_fw is reachable via two paths (firewalls_vms and
      # firewalls_private_subnets), so the prog must dedupe to avoid
      # creating its tag key/value twice.
      direct_fw = Firewall.create(name: "fw-direct", location_id: location.id, project_id: project.id)
      FirewallRule.create(firewall_id: direct_fw.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(80...81))
      vm = create_vm(project_id: project.id, location_id: location.id, name: "vm-1")
      Nic.create(private_subnet_id: ps.id, vm_id: vm.id, private_ipv4: "10.0.0.5",
        private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::", mac: "00:00:00:00:00:aa",
        name: "nic-1", state: "active")
      DB[:firewalls_vms].insert(firewall_id: direct_fw.id, vm_id: vm.id)
      DB[:firewalls_private_subnets].insert(firewall_id: direct_fw.id, private_subnet_id: ps.id)

      created = []
      allow(crm_client).to receive(:create_tag_key) do |tk|
        created << tk.short_name
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
          done?: true, name: "tk-op", response: {"name" => "tagKeys/#{tk.short_name}"}, error: nil)
      end
      tag_values = {}
      allow(crm_client).to receive(:create_tag_value) do |tv|
        tag_values[tv.parent] = "tagValues/#{tv.parent}-active"
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
          done?: true, name: "tv-op", response: {"name" => tag_values[tv.parent]}, error: nil)
      end
      allow(global_ops_client).to receive(:get).and_return(done_compute_op)

      added_rules = []
      allow(nfp_client).to receive(:add_rule) do |args|
        added_rules << args[:firewall_policy_rule_resource]
        lro_op
      end
      allow(nfp_client).to receive(:get) do
        v1::FirewallPolicy.new(rules: added_rules.dup)
      end

      # Entry 1: firewall A's tag pair + first rule -> nap. Entry 2: A is
      # converged, firewall B's tag pair + rule -> nap. Entry 3: pop.
      expect { nx.update_firewall_rules }.to nap(5)
      expect { nx.update_firewall_rules }.to nap(5)
      expect { nx.update_firewall_rules }.to hop("update_firewall_rules", "Vnet::Gcp::VpcNexus")

      expect(created).to contain_exactly(
        "ubicloud-fw-#{firewall.ubid}",
        "ubicloud-fw-#{direct_fw.ubid}",
      )
      expect(added_rules.length).to eq(2)
    end

    it "syncs empty rules for firewall with no rules but still creates tag key/value" do
      fw_rule.destroy

      expect(crm_client).to receive(:create_tag_key).and_return(crm_done_op)
      expect(crm_client).to receive(:create_tag_value)
      # sync_firewall_rules is still called with empty rules to clean up
      # stale policy rules that previously targeted this tag value.
      expect(nfp_client).to receive(:get).and_return(
        v1::FirewallPolicy.new(rules: []),
      )
      expect(nfp_client).not_to receive(:add_rule)

      expect { nx.update_firewall_rules }.to hop("update_firewall_rules", "Vnet::Gcp::VpcNexus")
    end

    it "pops cleanly when the VPC has no firewalls" do
      firewall.disassociate_from_private_subnet(ps, apply_firewalls: false)
      # No list_tag_keys matches will be made until cleanup; no firewalls to loop.

      expect(crm_client).not_to receive(:create_tag_key)

      expect { nx.update_firewall_rules }.to hop("update_firewall_rules", "Vnet::Gcp::VpcNexus")
    end

    it "reuses cached tag values from fw_tag_data without recreating tags" do
      fw_rule.destroy
      refresh_frame(nx, new_values: {"fw_tag_data" => {firewall.ubid => fw_tag_value_name}})

      expect(crm_client).not_to receive(:create_tag_key)
      expect(crm_client).not_to receive(:create_tag_value)
      expect(nfp_client).not_to receive(:add_rule)

      expect { nx.update_firewall_rules }.to hop("update_firewall_rules", "Vnet::Gcp::VpcNexus")
    end

    it "runs cleanup_orphaned_firewall_rules after syncing firewalls" do
      fw_rule.destroy
      expect(nx).to receive(:cleanup_orphaned_firewall_rules).and_call_original
      # cleanup_orphaned_firewall_rules calls list_tag_keys; default stub
      # returns empty list so cleanup is a no-op.
      expect { nx.update_firewall_rules }.to hop("update_firewall_rules", "Vnet::Gcp::VpcNexus")
    end
  end

  describe "ensure_firewall_tag_key" do
    it "naps when CRM operation is not done and saves op name in frame" do
      pending_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: false, name: "op-pending")
      expect(crm_client).to receive(:create_tag_key).and_return(pending_op)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to nap(5)
      expect(st.stack.first["pending_tag_key_crm_op"]).to eq("op-pending")
      expect(st.stack.first["pending_tag_key_fw_ubid"]).to eq(firewall.ubid)
    end

    it "polls pending operation on re-entry and returns name" do
      refresh_frame(nx, new_values: {
        "pending_tag_key_crm_op" => "operations/pending-tk",
        "pending_tag_key_fw_ubid" => firewall.ubid,
      })

      done_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/pending-tk", response: {"name" => "tagKeys/polled-1"}, error: nil)
      expect(crm_client).to receive(:get_operation).with("operations/pending-tk").and_return(done_op)

      result = nx.send(:ensure_firewall_tag_key, firewall)
      expect(result).to eq("tagKeys/polled-1")
      expect(st.stack.first["pending_tag_key_crm_op"]).to be_nil
    end

    it "handles 409 conflict by looking up existing key" do
      expect(crm_client).to receive(:create_tag_key)
        .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))
      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{firewall.ubid}", name: "tagKeys/existing-1")
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [tk], next_page_token: nil)
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      expect(nx.send(:ensure_firewall_tag_key, firewall)).to eq("tagKeys/existing-1")
    end

    it "handles ALREADY_EXISTS from CRM LRO by looking up existing key" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 6, message: "tag key already exists")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_key).and_return(op)
      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{firewall.ubid}", name: "tagKeys/existing-lro-1")
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [tk], next_page_token: nil)
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      expect(nx.send(:ensure_firewall_tag_key, firewall)).to eq("tagKeys/existing-lro-1")
    end

    # Regression: GCP CRM list_tag_keys returns at most 100 entries per page.
    # Once a project accumulates >100 tag keys, the target tag key for an
    # ALREADY_EXISTS retry can land on page 2; without pagination the lookup
    # falls back to "conflict but not found", the strand label rolls back the
    # cleared pending op, and the prog re-polls forever (HA test hang
    # observed 2026-05-07).
    it "paginates list_tag_keys to find target on page 2 after ALREADY_EXISTS" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 6, message: "tag key already exists")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_key).and_return(op)
      filler = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-other", name: "tagKeys/other")
      target = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{firewall.ubid}", name: "tagKeys/page2-target")
      page1 = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse,
        tag_keys: [filler], next_page_token: "tok-2")
      page2 = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse,
        tag_keys: [target], next_page_token: nil)
      expect(crm_client).to receive(:list_tag_keys)
        .with(parent: "projects/test-gcp-project", page_token: nil).ordered.and_return(page1)
      expect(crm_client).to receive(:list_tag_keys)
        .with(parent: "projects/test-gcp-project", page_token: "tok-2").ordered.and_return(page2)

      expect(nx.send(:ensure_firewall_tag_key, firewall)).to eq("tagKeys/page2-target")
    end

    it "naps on non-ALREADY_EXISTS LRO errors so a fresh create is issued" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 7, message: "PERMISSION_DENIED")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to nap(5)
    end

    it "re-raises non-409 client errors" do
      expect(crm_client).to receive(:create_tag_key)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to raise_error(Google::Apis::ClientError)
    end

    it "falls back to lookup when LRO response has no name" do
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "op-1", response: nil, error: nil)
      expect(crm_client).to receive(:create_tag_key).and_return(op)
      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{firewall.ubid}", name: "tagKeys/lookup-1")
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [tk], next_page_token: nil),
      )

      expect(nx.send(:ensure_firewall_tag_key, firewall)).to eq("tagKeys/lookup-1")
    end

    it "raises when LRO response and lookup both fail" do
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", response: nil, error: nil)
      expect(crm_client).to receive(:create_tag_key).and_return(op)
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [], next_page_token: nil),
      )

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to raise_error(/created but name not found/)
    end

    it "raises on 409 when lookup fails" do
      expect(crm_client).to receive(:create_tag_key)
        .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: nil, next_page_token: nil),
      )

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to raise_error(/conflict but not found/)
    end

    it "naps again when polling pending operation that is still not done" do
      refresh_frame(nx, new_values: {
        "pending_tag_key_crm_op" => "operations/still-pending",
        "pending_tag_key_fw_ubid" => firewall.ubid,
      })
      still_pending = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: false)
      expect(crm_client).to receive(:get_operation).with("operations/still-pending").and_return(still_pending)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to nap(5)
    end

    it "ignores pending op from a different firewall and creates fresh" do
      refresh_frame(nx, new_values: {
        "pending_tag_key_crm_op" => "operations/other-fw",
        "pending_tag_key_fw_ubid" => "fwubid-other",
      })
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "op-1", response: {"name" => "tagKeys/fresh-1"}, error: nil)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      expect(nx.send(:ensure_firewall_tag_key, firewall)).to eq("tagKeys/fresh-1")
    end

    it "naps with the pending op cleared when the polled op has a terminal error" do
      refresh_frame(nx, new_values: {
        "pending_tag_key_crm_op" => "operations/tk-error",
        "pending_tag_key_fw_ubid" => firewall.ubid,
      })
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 13, message: "INTERNAL")
      error_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/tk-error", error:)
      expect(crm_client).to receive(:get_operation).with("operations/tk-error").and_return(error_op)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to nap(5)
      expect(nx.strand.stack.first["pending_tag_key_crm_op"]).to be_nil
    end

    it "falls back to lookup when polled op has nil response" do
      refresh_frame(nx, new_values: {
        "pending_tag_key_crm_op" => "operations/no-name",
        "pending_tag_key_fw_ubid" => firewall.ubid,
      })
      no_name_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/no-name", response: nil, error: nil)
      expect(crm_client).to receive(:get_operation).with("operations/no-name").and_return(no_name_op)
      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{firewall.ubid}", name: "tagKeys/poll-1")
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [tk], next_page_token: nil),
      )

      expect(nx.send(:ensure_firewall_tag_key, firewall)).to eq("tagKeys/poll-1")
    end
  end

  describe "ensure_tag_value" do
    it "creates and returns name from op response" do
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "op-1", response: {"name" => "tagValues/new-1"}, error: nil)
      expect(crm_client).to receive(:create_tag_value).and_return(op)

      expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/new-1")
    end

    it "falls back to lookup when response has no name" do
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", response: nil, error: nil)
      expect(crm_client).to receive(:create_tag_value).and_return(op)
      tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: "tagValues/lookup-1")
      expect(crm_client).to receive(:list_tag_values).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [tv], next_page_token: nil),
      )

      expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/lookup-1")
    end

    it "raises when response nil and lookup fails" do
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", response: nil, error: nil)
      expect(crm_client).to receive(:create_tag_value).and_return(op)
      expect(crm_client).to receive(:list_tag_values).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: nil, next_page_token: nil),
      )

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(/created but name not found/)
    end

    it "handles 409 conflict by looking up existing" do
      expect(crm_client).to receive(:create_tag_value)
        .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))
      tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: "tagValues/existing-1")
      expect(crm_client).to receive(:list_tag_values).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [tv], next_page_token: nil),
      )

      expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/existing-1")
    end

    it "raises on 409 when lookup fails" do
      expect(crm_client).to receive(:create_tag_value)
        .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))
      expect(crm_client).to receive(:list_tag_values).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: nil, next_page_token: nil),
      )

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(/conflict but not found/)
    end

    it "re-raises non-409 client errors" do
      expect(crm_client).to receive(:create_tag_value)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(Google::Apis::ClientError)
    end

    it "handles ALREADY_EXISTS from LRO" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 6, message: "already exists")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_value).and_return(op)
      tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: "tagValues/existing-lro-1")
      expect(crm_client).to receive(:list_tag_values).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [tv], next_page_token: nil),
      )

      expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/existing-lro-1")
    end

    it "paginates list_tag_values to find target on page 2 after ALREADY_EXISTS" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 6, message: "already exists")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_value).and_return(op)
      filler = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "stale", name: "tagValues/stale")
      target = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: "tagValues/page2")
      page1 = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse,
        tag_values: [filler], next_page_token: "tv-tok-2")
      page2 = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse,
        tag_values: [target], next_page_token: nil)
      expect(crm_client).to receive(:list_tag_values)
        .with(parent: "tagKeys/123", page_token: nil).ordered.and_return(page1)
      expect(crm_client).to receive(:list_tag_values)
        .with(parent: "tagKeys/123", page_token: "tv-tok-2").ordered.and_return(page2)

      expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/page2")
    end

    it "naps on non-ALREADY_EXISTS LRO errors so a fresh create is issued" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 7, message: "PERMISSION_DENIED")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_value).and_return(op)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to nap(5)
    end

    it "naps when op is not done and saves frame state" do
      pending_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: false, name: "op-tv-pending")
      expect(crm_client).to receive(:create_tag_value).and_return(pending_op)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to nap(5)
      expect(st.stack.first["pending_tag_value_crm_op"]).to eq("op-tv-pending")
      expect(st.stack.first["pending_tag_value_parent"]).to eq("tagKeys/123")
    end

    it "polls pending operation on re-entry and returns name" do
      refresh_frame(nx, new_values: {
        "pending_tag_value_crm_op" => "operations/pending-tv",
        "pending_tag_value_parent" => "tagKeys/123",
      })
      done_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/pending-tv", response: {"name" => "tagValues/polled-1"}, error: nil)
      expect(crm_client).to receive(:get_operation).with("operations/pending-tv").and_return(done_op)

      expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/polled-1")
    end

    it "naps when polling pending op that is still not done" do
      refresh_frame(nx, new_values: {
        "pending_tag_value_crm_op" => "operations/still-pending",
        "pending_tag_value_parent" => "tagKeys/123",
      })
      still_pending = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: false)
      expect(crm_client).to receive(:get_operation).with("operations/still-pending").and_return(still_pending)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to nap(5)
    end

    it "ignores pending op from a different parent and creates fresh" do
      refresh_frame(nx, new_values: {
        "pending_tag_value_crm_op" => "operations/other-parent",
        "pending_tag_value_parent" => "tagKeys/999",
      })
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", response: {"name" => "tagValues/fresh-1"}, error: nil)
      expect(crm_client).to receive(:create_tag_value).and_return(op)

      expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/fresh-1")
    end

    it "naps with the pending op cleared when the polled op has a terminal error" do
      refresh_frame(nx, new_values: {
        "pending_tag_value_crm_op" => "operations/tv-error",
        "pending_tag_value_parent" => "tagKeys/123",
      })
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 13, message: "INTERNAL")
      error_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/tv-error", error:)
      expect(crm_client).to receive(:get_operation).with("operations/tv-error").and_return(error_op)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to nap(5)
      expect(nx.strand.stack.first["pending_tag_value_crm_op"]).to be_nil
    end

    it "falls back to lookup when polled op has nil response" do
      refresh_frame(nx, new_values: {
        "pending_tag_value_crm_op" => "operations/tv-no-name",
        "pending_tag_value_parent" => "tagKeys/123",
      })
      no_name_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/tv-no-name", response: nil, error: nil)
      expect(crm_client).to receive(:get_operation).with("operations/tv-no-name").and_return(no_name_op)
      tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: "tagValues/fallback-1")
      expect(crm_client).to receive(:list_tag_values).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [tv], next_page_token: nil),
      )

      expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/fallback-1")
    end
  end

  describe "sync_tag_policy_rules" do
    let(:tag_value) { "tagValues/test-tv" }
    let(:desired) {
      [{
        direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: [tag_value],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }]
    }

    def existing_rule(priority: 10000, src_ranges: ["0.0.0.0/0"], ports: ["22"], tags: [tag_value], action: "allow", proto: "tcp")
      v1::FirewallPolicyRule.new(
        priority:, direction: "INGRESS", action:,
        match: v1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: src_ranges,
          layer4_configs: [v1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: proto, ports:)],
        ),
        target_secure_tags: tags.map { |t| v1::FirewallPolicyRuleSecureTag.new(name: t) },
      )
    end

    it "adds a missing rule, saves its LRO in the frame, and naps" do
      expect(nfp_client).to receive(:get).and_return(v1::FirewallPolicy.new(rules: []))
      expect(nfp_client).to receive(:add_rule) do |args|
        rule = args[:firewall_policy_rule_resource]
        expect(rule.priority).to eq(10000)
        expect(rule.target_secure_tags.first.name).to eq(tag_value)
        lro_op
      end

      expect { nx.send(:sync_tag_policy_rules, desired, tag_value) }.to nap(5)
      expect(st.stack.first["policy_rule_ops"]).to eq(["op-12345"])
    end

    it "submits every pending add in one entry with distinct priorities" do
      two_desired = desired + [{
        direction: "INGRESS",
        source_ranges: ["::/0"],
        target_secure_tags: [tag_value],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }]
      expect(nfp_client).to receive(:get).and_return(v1::FirewallPolicy.new(rules: []))
      priorities = []
      ops = ["op-a", "op-b"].map { |n| instance_double(Gapic::GenericLRO::Operation, name: n) }
      expect(nfp_client).to receive(:add_rule).twice do |args|
        priorities << args[:firewall_policy_rule_resource].priority
        ops[priorities.length - 1]
      end

      expect { nx.send(:sync_tag_policy_rules, two_desired, tag_value) }.to nap(5)
      expect(priorities).to eq([10000, 10001])
      expect(st.stack.first["policy_rule_ops"]).to eq(["op-a", "op-b"])
    end

    it "removes all unmatched stale rules in one entry and naps" do
      policy = v1::FirewallPolicy.new(rules: [
        existing_rule(priority: 10000, src_ranges: ["10.0.0.0/8"], ports: ["80"]),
        existing_rule(priority: 10001, src_ranges: ["10.1.0.0/16"], ports: ["81"]),
      ])
      expect(nfp_client).to receive(:get).and_return(policy)
      removed = []
      expect(nfp_client).to receive(:remove_rule).twice do |args|
        removed << args[:priority]
        lro_op
      end

      expect { nx.send(:sync_tag_policy_rules, [], tag_value) }.to nap(5)
      expect(removed).to contain_exactly(10000, 10001)
    end

    it "naps without saving an op when the stale rule is already gone" do
      policy = v1::FirewallPolicy.new(rules: [existing_rule(src_ranges: ["10.0.0.0/8"], ports: ["80"])])
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).to receive(:remove_rule).and_raise(Google::Cloud::NotFoundError.new("gone"))

      expect { nx.send(:sync_tag_policy_rules, [], tag_value) }.to nap(5)
      expect(st.stack.first["policy_rule_ops"]).to be_nil
    end

    it "skips priorities already in use by any rule when adding" do
      occupied_rule = v1::FirewallPolicyRule.new(
        priority: 10000, direction: "INGRESS", action: "deny",
        match: v1::FirewallPolicyRuleMatcher.new(src_ip_ranges: ["192.168.0.0/16"]),
      )
      expect(nfp_client).to receive(:get).and_return(v1::FirewallPolicy.new(rules: [occupied_rule]))
      expect(nfp_client).to receive(:add_rule) do |args|
        expect(args[:firewall_policy_rule_resource].priority).to eq(10001)
        lro_op
      end

      expect { nx.send(:sync_tag_policy_rules, desired, tag_value) }.to nap(5)
    end

    it "returns without mutating when everything matches" do
      policy = v1::FirewallPolicy.new(rules: [existing_rule])
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).not_to receive(:add_rule)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:sync_tag_policy_rules, desired, tag_value)
    end

    it "adds before removing and does not reuse a stale rule's priority" do
      # The stale rule keeps its slot until the add lands, so the new rule
      # must take a fresh priority; the remove happens on a later entry.
      policy = v1::FirewallPolicy.new(rules: [existing_rule(src_ranges: ["10.0.0.0/8"], ports: ["80"])])
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).not_to receive(:remove_rule)
      expect(nfp_client).to receive(:add_rule) do |args|
        expect(args[:firewall_policy_rule_resource].priority).to eq(10001)
        lro_op
      end

      expect { nx.send(:sync_tag_policy_rules, desired, tag_value) }.to nap(5)
    end

    it "adds a fresh rule instead of rewriting an existing one when ranges change" do
      # An in-place rewrite would drop coverage for any CIDR moving to a
      # different rule; adding first keeps the live set a superset.
      policy = v1::FirewallPolicy.new(rules: [existing_rule(priority: 10007, src_ranges: ["1.1.1.1/32"])])
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).not_to receive(:remove_rule)
      expect(nfp_client).to receive(:add_rule) do |args|
        rule = args[:firewall_policy_rule_resource]
        expect(rule.priority).to eq(10000)
        expect(rule.match.src_ip_ranges).to eq(["0.0.0.0/0"])
        lro_op
      end

      expect { nx.send(:sync_tag_policy_rules, desired, tag_value) }.to nap(5)
    end

    it "adds the packed rule before removing per-CIDR rules when migrating" do
      packed = [{
        direction: "INGRESS",
        source_ranges: ["1.1.1.1/32", "2.2.2.2/32"],
        target_secure_tags: [tag_value],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }]
      policy = v1::FirewallPolicy.new(rules: [
        existing_rule(priority: 10005, src_ranges: ["2.2.2.2/32"]),
        existing_rule(priority: 10002, src_ranges: ["1.1.1.1/32"]),
      ])
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).not_to receive(:remove_rule)
      expect(nfp_client).to receive(:add_rule) do |args|
        rule = args[:firewall_policy_rule_resource]
        expect(rule.priority).to eq(10000)
        expect(rule.match.src_ip_ranges.to_a).to eq(["1.1.1.1/32", "2.2.2.2/32"])
        lro_op
      end

      expect { nx.send(:sync_tag_policy_rules, packed, tag_value) }.to nap(5)
    end

    it "never narrows an existing rule when ranges redistribute between rules" do
      # Chunk-boundary shift: 2.2.2.2 moves from the first rule to the
      # second. Rewriting either rule in place would leave 2.2.2.2
      # uncovered until a later entry; both desired rules must be added
      # before any existing rule is touched.
      redistributed = [
        {
          direction: "INGRESS",
          source_ranges: ["1.1.1.1/32"],
          target_secure_tags: [tag_value],
          layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
        },
        {
          direction: "INGRESS",
          source_ranges: ["2.2.2.2/32", "3.3.3.3/32"],
          target_secure_tags: [tag_value],
          layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
        },
      ]
      policy = v1::FirewallPolicy.new(rules: [
        existing_rule(priority: 10000, src_ranges: ["1.1.1.1/32", "2.2.2.2/32"]),
        existing_rule(priority: 10001, src_ranges: ["3.3.3.3/32"]),
      ])
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).not_to receive(:remove_rule)
      priorities = []
      expect(nfp_client).to receive(:add_rule).twice do |args|
        priorities << args[:firewall_policy_rule_resource].priority
        lro_op
      end

      expect { nx.send(:sync_tag_policy_rules, redistributed, tag_value) }.to nap(5)
      expect(priorities).to eq([10002, 10003])
    end

    it "ignores rules for other tag values" do
      policy = v1::FirewallPolicy.new(rules: [existing_rule(tags: ["tagValues/other-tv"])])
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:sync_tag_policy_rules, [], tag_value)
    end

    it "raises when no priority slot is free" do
      full_band = Set.new(described_class::TAG_RULE_BASE_PRIORITY..described_class::TAG_RULE_MAX_PRIORITY)

      expect { nx.send(:next_free_priority, full_band) }
        .to raise_error(RuntimeError, /No available firewall policy priority slot/)
    end
  end

  describe "submit_policy_mutations" do
    it "keeps already-accepted ops when the policy pushes back mid-batch" do
      first = -> { lro_op }
      busy = -> { raise Google::Cloud::InvalidArgumentError, "resource is not ready" }
      never = -> { raise "must not be called after pushback" }
      expect(Clog).to receive(:emit).with("GCP firewall policy mutation submitted", anything).and_call_original
      expect(Clog).to receive(:emit).with("GCP firewall policy busy, deferring remaining mutations", anything).and_call_original

      expect { nx.send(:submit_policy_mutations, [first, busy, never]) }.to nap(5)
      expect(st.stack.first["policy_rule_ops"]).to eq(["op-12345"])
    end

    it "naps without raising on a priority collision from a concurrent writer" do
      expect {
        nx.send(:submit_policy_mutations, [-> { raise Google::Cloud::AlreadyExistsError, "exists" }])
      }.to nap(5)
      expect {
        nx.send(:submit_policy_mutations, [-> { raise Google::Cloud::InvalidArgumentError, "must all have different priorities, same priorities found" }])
      }.to nap(5)
    end

    it "re-raises InvalidArgumentError unrelated to serialization" do
      expect {
        nx.send(:submit_policy_mutations, [-> { raise Google::Cloud::InvalidArgumentError, "invalid field" }])
      }.to raise_error(Google::Cloud::InvalidArgumentError)
    end

    it "skips nil results without recording an op" do
      expect { nx.send(:submit_policy_mutations, [-> {}]) }.to nap(5)
      expect(st.stack.first["policy_rule_ops"]).to be_nil
    end
  end

  describe "delete_policy_rule" do
    it "removes the rule" do
      expect(nfp_client).to receive(:remove_rule).and_return(lro_op)
      nx.send(:delete_policy_rule, 10000)
    end

    it "swallows NotFoundError" do
      expect(nfp_client).to receive(:remove_rule).and_raise(Google::Cloud::NotFoundError.new("not found"))
      nx.send(:delete_policy_rule, 10000)
    end

    it "swallows InvalidArgumentError" do
      expect(nfp_client).to receive(:remove_rule).and_raise(Google::Cloud::InvalidArgumentError.new("invalid"))
      nx.send(:delete_policy_rule, 10000)
    end
  end

  describe "cleanup_orphaned_firewall_rules" do
    let(:vpc_purpose_data) {
      {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/1234567890"}
    }
    let(:orphan_fw_ubid) { Firewall.generate_ubid.to_s }
    let(:orphan_tag_key_name) { "tagKeys/orphan-123" }
    let(:orphan_tag_value_name) { "tagValues/orphan-tv-1" }

    it "deletes rules, tag value and tag key for deleted firewalls" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name,
        purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk], next_page_token: nil),
      )
      orphan_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue,
        short_name: "active", name: orphan_tag_value_name)
      expect(crm_client).to receive(:list_tag_values).with(parent: orphan_tag_key_name, page_token: nil).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [orphan_tv], next_page_token: nil),
      )
      rule = v1::FirewallPolicyRule.new(
        priority: 10005, action: "allow",
        target_secure_tags: [v1::FirewallPolicyRuleSecureTag.new(name: orphan_tag_value_name)],
      )
      expect(nfp_client).to receive(:get).and_return(v1::FirewallPolicy.new(rules: [rule]))
      expect(nfp_client).to receive(:remove_rule).with(hash_including(priority: 10005)).and_return(lro_op)
      expect(crm_client).to receive(:delete_tag_value).with(orphan_tag_value_name)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips firewalls attached to subnets in this VPC (active)" do
      # firewall is attached to ps which is in gcp_vpc
      active_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{firewall.ubid}", name: "tagKeys/active-1",
        purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [active_tk], next_page_token: nil),
      )
      expect(nfp_client).not_to receive(:get)
      expect(crm_client).not_to receive(:delete_tag_key)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips firewalls attached to any subnet globally via UNION guard" do
      # Another VPC's subnet has this firewall; must not be orphaned.
      other_fw = Firewall.create(name: "other-fw", location_id: location.id, project_id: project.id)
      other_ps = PrivateSubnet.create(name: "other-ps", location_id: location.id, project_id: project.id,
        net6: "fd91:4ef3:a586:943d::/64", net4: "192.168.9.0/24")
      DB[:firewalls_private_subnets].insert(firewall_id: other_fw.id, private_subnet_id: other_ps.id)

      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{other_fw.ubid}", name: "tagKeys/cross-1",
        purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [tk], next_page_token: nil),
      )
      expect(nfp_client).not_to receive(:get)
      expect(crm_client).not_to receive(:delete_tag_key)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips firewalls attached to VMs globally via UNION guard" do
      vm_fw = Firewall.create(name: "vm-fw", location_id: location.id, project_id: project.id)
      other_vm_id = DB[:vm].insert(id: Vm.generate_uuid,
        unix_user: "x", public_key: "x", name: "vm-x", boot_image: "img",
        family: "standard", cores: 1, vcpus: 1, memory_gib: 1,
        project_id: project.id, location_id: location.id)
      DB[:firewalls_vms].insert(firewall_id: vm_fw.id, vm_id: other_vm_id)

      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{vm_fw.ubid}", name: "tagKeys/vm-attached",
        purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [tk], next_page_token: nil),
      )
      expect(nfp_client).not_to receive(:get)
      expect(crm_client).not_to receive(:delete_tag_key)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips tag keys from other VPCs (different network_self_link)" do
      other_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name,
        purpose: "GCE_FIREWALL",
        purpose_data: {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/9999999999"})
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [other_tk], next_page_token: nil),
      )
      expect(nfp_client).not_to receive(:get)
      expect(crm_client).not_to receive(:delete_tag_key)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips tag keys with nil purpose_data" do
      nil_pd = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name,
        purpose: "GCE_FIREWALL", purpose_data: nil)
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [nil_pd], next_page_token: nil),
      )
      expect(nfp_client).not_to receive(:get)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips non-GCE_FIREWALL tag keys" do
      non_fw = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-weird", name: "tagKeys/other-1", purpose: nil)
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [non_fw], next_page_token: nil),
      )
      expect(nfp_client).not_to receive(:get)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips tag keys without matching short_name prefix" do
      subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-subnet-x", name: "tagKeys/subnet-1", purpose: "GCE_FIREWALL")
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [subnet_tk], next_page_token: nil),
      )
      expect(nfp_client).not_to receive(:get)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "returns early when no tag keys exist" do
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: nil, next_page_token: nil),
      )
      expect(nfp_client).not_to receive(:get)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "deletes tag key even when no tag value exists" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name,
        purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk], next_page_token: nil),
      )
      expect(crm_client).to receive(:list_tag_values).with(parent: orphan_tag_key_name, page_token: nil).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: nil, next_page_token: nil),
      )
      expect(nfp_client).not_to receive(:get)
      expect(crm_client).not_to receive(:delete_tag_value)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips non-allow rules but still deletes tag value and key" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name,
        purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk], next_page_token: nil),
      )
      orphan_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue,
        short_name: "active", name: orphan_tag_value_name)
      expect(crm_client).to receive(:list_tag_values).with(parent: orphan_tag_key_name, page_token: nil).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [orphan_tv], next_page_token: nil),
      )
      deny_rule = v1::FirewallPolicyRule.new(
        priority: 10005, action: "deny",
        target_secure_tags: [v1::FirewallPolicyRuleSecureTag.new(name: orphan_tag_value_name)],
      )
      expect(nfp_client).to receive(:get).and_return(v1::FirewallPolicy.new(rules: [deny_rule]))
      expect(nfp_client).not_to receive(:remove_rule)
      expect(crm_client).to receive(:delete_tag_value).with(orphan_tag_value_name)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips allow rules whose target tag doesn't match the orphan tag value" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name,
        purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk], next_page_token: nil),
      )
      orphan_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue,
        short_name: "active", name: orphan_tag_value_name)
      expect(crm_client).to receive(:list_tag_values).with(parent: orphan_tag_key_name, page_token: nil).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [orphan_tv], next_page_token: nil),
      )
      unrelated_rule = v1::FirewallPolicyRule.new(
        priority: 10005, action: "allow",
        target_secure_tags: [v1::FirewallPolicyRuleSecureTag.new(name: "tagValues/other-tv")],
      )
      expect(nfp_client).to receive(:get).and_return(v1::FirewallPolicy.new(rules: [unrelated_rule]))
      expect(nfp_client).not_to receive(:remove_rule)
      expect(crm_client).to receive(:delete_tag_value).with(orphan_tag_value_name)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "propagates errors from list_tag_values during orphan cleanup" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name,
        purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)
      expect(crm_client).to receive(:list_tag_keys).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk], next_page_token: nil),
      )
      expect(crm_client).to receive(:list_tag_values)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.send(:cleanup_orphaned_firewall_rules) }.to raise_error(Google::Apis::ClientError)
    end

    it "propagates errors from list_tag_keys" do
      expect(crm_client).to receive(:list_tag_keys).and_raise(Google::Cloud::Error.new("error"))

      expect { nx.send(:cleanup_orphaned_firewall_rules) }.to raise_error(Google::Cloud::Error)
    end

    it "paginates list_tag_keys and includes orphan candidates from later pages" do
      page1_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{firewall.ubid}", name: "tagKeys/active-1",
        purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)
      page2_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name,
        purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)
      page1 = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse,
        tag_keys: [page1_tk], next_page_token: "orphan-tok-2")
      page2 = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse,
        tag_keys: [page2_tk], next_page_token: nil)
      expect(crm_client).to receive(:list_tag_keys)
        .with(parent: "projects/test-gcp-project", page_token: nil).ordered.and_return(page1)
      expect(crm_client).to receive(:list_tag_keys)
        .with(parent: "projects/test-gcp-project", page_token: "orphan-tok-2").ordered.and_return(page2)
      expect(crm_client).to receive(:list_tag_values).with(parent: orphan_tag_key_name, page_token: nil).and_return(
        instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: nil, next_page_token: nil),
      )
      # Active tag key (page 1) is NOT deleted; only the orphan from page 2 is.
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name)

      nx.send(:cleanup_orphaned_firewall_rules)
    end
  end

  describe "build_tag_based_policy_rules" do
    it "merges ports of the same CIDR and protocol into one rule" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23), protocol: "tcp"),
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(443...444), protocol: "tcp"),
      ]
      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(1)
      expect(result.first[:layer4_configs].first[:ports]).to contain_exactly("22", "443")
    end

    it "packs CIDRs sharing a port profile into one rule with sorted ranges" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "9.9.9.9/32", port_range: Sequel.pg_range(5432...5433), protocol: "tcp"),
        FirewallRule.create(firewall_id: firewall.id, cidr: "1.1.1.1/32", port_range: Sequel.pg_range(5432...5433), protocol: "tcp"),
        FirewallRule.create(firewall_id: firewall.id, cidr: "9.9.9.9/32", port_range: Sequel.pg_range(6432...6433), protocol: "tcp"),
        FirewallRule.create(firewall_id: firewall.id, cidr: "1.1.1.1/32", port_range: Sequel.pg_range(6432...6433), protocol: "tcp"),
      ]
      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(1)
      expect(result.first[:source_ranges]).to eq(["1.1.1.1/32", "9.9.9.9/32"])
      expect(result.first[:layer4_configs]).to eq([{ip_protocol: "tcp", ports: ["5432", "6432"]}])
    end

    it "keeps CIDRs with different port profiles in separate rules" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "1.1.1.1/32", port_range: Sequel.pg_range(5432...5433), protocol: "tcp"),
        FirewallRule.create(firewall_id: firewall.id, cidr: "2.2.2.2/32", port_range: Sequel.pg_range(22...23), protocol: "tcp"),
      ]
      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(2)
      expect(result.map { it[:source_ranges] }).to contain_exactly(["1.1.1.1/32"], ["2.2.2.2/32"])
    end

    it "never mixes IPv4 and IPv6 ranges in one rule" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23), protocol: "tcp"),
        FirewallRule.create(firewall_id: firewall.id, cidr: "::/0", port_range: Sequel.pg_range(22...23), protocol: "tcp"),
      ]
      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(2)
      expect(result.map { it[:source_ranges] }).to contain_exactly(["0.0.0.0/0"], ["::/0"])
    end

    it "chunks ranges beyond the per-rule limit into multiple rules" do
      port_range = Sequel.pg_range(22...23)
      rules = Array.new(257) { |i|
        instance_double(FirewallRule, cidr: "10.#{i / 250}.#{i % 250}.1/32", protocol: "tcp", port_range:)
      }
      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.map { it[:source_ranges].length }).to eq([256, 1])
      expect(result.flat_map { it[:source_ranges] }).to match_array(rules.map(&:cidr))
    end

    it "formats a multi-port range" do
      rules = [FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(80...9999), protocol: "tcp")]
      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.first[:layer4_configs].first[:ports]).to eq(["80-9998"])
    end

    it "formats a single-port range as a single number" do
      rules = [FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(5432...5433), protocol: "tcp")]
      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.first[:layer4_configs].first[:ports]).to eq(["5432"])
    end

    it "returns empty for empty input" do
      expect(nx.send(:build_tag_based_policy_rules, [], tag_value_name: "tagValues/tv-1")).to eq([])
    end
  end

  describe "tag_policy_rule_matches?" do
    def make_rule(direction: "INGRESS", action: "allow", src_ranges: ["0.0.0.0/0"], tags: ["tagValues/test-tv"], l4: [{proto: "tcp", ports: ["22"]}])
      v1::FirewallPolicyRule.new(
        direction:, action:,
        match: v1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: src_ranges,
          layer4_configs: l4.map { |c|
            v1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: c[:proto], ports: c[:ports])
          },
        ),
        target_secure_tags: tags.map { |t| v1::FirewallPolicyRuleSecureTag.new(name: t) },
      )
    end

    let(:desired) {
      {
        direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: ["tagValues/test-tv"],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }
    }

    it "returns true for a match" do
      expect(nx.send(:tag_policy_rule_matches?, make_rule, desired)).to be true
    end

    it "returns false when match is nil" do
      rule = v1::FirewallPolicyRule.new(direction: "INGRESS", action: "allow")
      expect(nx.send(:tag_policy_rule_matches?, rule, desired)).to be false
    end

    it "returns false for wrong direction" do
      expect(nx.send(:tag_policy_rule_matches?, make_rule(direction: "EGRESS"), desired)).to be false
    end

    it "returns false for wrong action" do
      expect(nx.send(:tag_policy_rule_matches?, make_rule(action: "deny"), desired)).to be false
    end

    it "returns false for different source ranges" do
      expect(nx.send(:tag_policy_rule_matches?, make_rule(src_ranges: ["10.0.0.0/8"]), desired)).to be false
    end

    it "returns false for different tag" do
      expect(nx.send(:tag_policy_rule_matches?, make_rule(tags: ["tagValues/other"]), desired)).to be false
    end

    it "returns false for different layer4 count" do
      r = make_rule(l4: [{proto: "tcp", ports: ["22"]}, {proto: "udp", ports: ["53"]}])
      expect(nx.send(:tag_policy_rule_matches?, r, desired)).to be false
    end

    it "matches with nil ports" do
      rule = make_rule(l4: [{proto: "all", ports: nil}])
      d = desired.merge(layer4_configs: [{ip_protocol: "all", ports: []}])
      expect(nx.send(:tag_policy_rule_matches?, rule, d)).to be true
    end

    it "matches when desired omits :ports entirely" do
      rule = make_rule(l4: [{proto: "all", ports: nil}])
      d = desired.merge(layer4_configs: [{ip_protocol: "all"}])
      expect(nx.send(:tag_policy_rule_matches?, rule, d)).to be true
    end
  end
end
