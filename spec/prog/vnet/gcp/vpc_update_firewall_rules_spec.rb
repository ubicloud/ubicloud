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

  let(:lro_op) { instance_double(Gapic::GenericLRO::Operation, name: "op-12345") }

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

    it "creates tag key/value, syncs rules, then pops" do
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

      expect { nx.update_firewall_rules }.to hop("update_firewall_rules", "Vnet::Gcp::VpcNexus")
    end

    it "covers firewalls attached to subnets and VMs in the VPC without duplicates" do
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
      expect(crm_client).to receive(:create_tag_key).twice do |tk|
        created << tk.short_name
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
          done?: true, name: "tk-op", response: {"name" => "tagKeys/#{tk.short_name}"}, error: nil)
      end
      expect(crm_client).to receive(:create_tag_value).twice do |tv|
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
          done?: true, name: "tv-op", response: {"name" => "tagValues/#{tv.parent}-active"}, error: nil)
      end
      expect(nfp_client).to receive(:add_rule).twice.and_return(lro_op)

      expect { nx.update_firewall_rules }.to hop("update_firewall_rules", "Vnet::Gcp::VpcNexus")
      expect(created).to contain_exactly(
        "ubicloud-fw-#{firewall.ubid}",
        "ubicloud-fw-#{direct_fw.ubid}",
      )
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

    it "skips firewalls already in fw_tag_data cache" do
      refresh_frame(nx, new_values: {"fw_tag_data" => {firewall.ubid => fw_tag_value_name}})

      expect(crm_client).not_to receive(:create_tag_key)
      expect(crm_client).not_to receive(:create_tag_value)
      expect(nfp_client).not_to receive(:add_rule)

      expect { nx.update_firewall_rules }.to hop("update_firewall_rules", "Vnet::Gcp::VpcNexus")
    end

    it "runs cleanup_orphaned_firewall_rules after syncing firewalls" do
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
      expect(st.reload.stack.first["pending_tag_key_crm_op"]).to be_nil
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

    it "re-raises non-ALREADY_EXISTS LRO errors" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 7, message: "PERMISSION_DENIED")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }
        .to raise_error(described_class::CrmOperationError, /PERMISSION_DENIED/) { |e| expect(e.code).to eq(7) }
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

    it "raises when polled pending op has error" do
      refresh_frame(nx, new_values: {
        "pending_tag_key_crm_op" => "operations/tk-error",
        "pending_tag_key_fw_ubid" => firewall.ubid,
      })
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 13, message: "INTERNAL")
      error_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/tk-error", error:)
      expect(crm_client).to receive(:get_operation).with("operations/tk-error").and_return(error_op)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }
        .to raise_error(described_class::CrmOperationError) { |e| expect(e.code).to eq(13) }
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

    it "re-raises non-ALREADY_EXISTS LRO errors" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 7, message: "PERMISSION_DENIED")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_value).and_return(op)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }
        .to raise_error(described_class::CrmOperationError) { |e| expect(e.code).to eq(7) }
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

    it "raises when polled pending op has error" do
      refresh_frame(nx, new_values: {
        "pending_tag_value_crm_op" => "operations/tv-error",
        "pending_tag_value_parent" => "tagKeys/123",
      })
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 13, message: "INTERNAL")
      error_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/tv-error", error:)
      expect(crm_client).to receive(:get_operation).with("operations/tv-error").and_return(error_op)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }
        .to raise_error(described_class::CrmOperationError) { |e| expect(e.code).to eq(13) }
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

  describe "sync_firewall_rules" do
    let(:tag_value) { "tagValues/tv-1" }

    it "partitions IPv4 and IPv6 rules and syncs" do
      ipv4_rule = FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23), protocol: "tcp")
      ipv6_rule = FirewallRule.create(firewall_id: firewall.id, cidr: "::/0", port_range: Sequel.pg_range(22...23), protocol: "tcp")
      empty_policy = v1::FirewallPolicy.new(rules: [])
      expect(nfp_client).to receive(:get).and_return(empty_policy)
      expect(nfp_client).to receive(:add_rule).twice.and_return(lro_op)

      nx.send(:sync_firewall_rules, [ipv4_rule, ipv6_rule], tag_value)
    end
  end

  describe "sync_tag_policy_rules" do
    let(:tag_value) { "tagValues/test-tv" }

    it "creates new rules when no existing rules" do
      empty_policy = v1::FirewallPolicy.new(rules: [])
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
        expect(rule.target_secure_tags.first.name).to eq(tag_value)
        lro_op
      end

      nx.send(:sync_tag_policy_rules, desired, tag_value)
    end

    it "deletes unmatched existing rules" do
      stale_rule = v1::FirewallPolicyRule.new(
        priority: 10000, direction: "INGRESS", action: "allow",
        match: v1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: ["10.0.0.0/8"],
          layer4_configs: [v1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "tcp", ports: ["80"])],
        ),
        target_secure_tags: [v1::FirewallPolicyRuleSecureTag.new(name: tag_value)],
      )
      policy = v1::FirewallPolicy.new(rules: [stale_rule])
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).to receive(:remove_rule).with(hash_including(priority: 10000)).and_return(lro_op)

      nx.send(:sync_tag_policy_rules, [], tag_value)
    end

    it "skips priorities already in use" do
      occupied_rule = v1::FirewallPolicyRule.new(
        priority: 10000, direction: "INGRESS", action: "deny",
        match: v1::FirewallPolicyRuleMatcher.new(src_ip_ranges: ["192.168.0.0/16"]),
      )
      policy = v1::FirewallPolicy.new(rules: [occupied_rule])
      expect(nfp_client).to receive(:get).and_return(policy)
      desired = [{
        direction: "INGRESS", source_ranges: ["0.0.0.0/0"],
        target_secure_tags: [tag_value],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }]
      expect(nfp_client).to receive(:add_rule) do |args|
        expect(args[:firewall_policy_rule_resource].priority).to eq(10001)
        lro_op
      end

      nx.send(:sync_tag_policy_rules, desired, tag_value)
    end

    it "skips matching existing rules" do
      existing = v1::FirewallPolicyRule.new(
        priority: 10000, direction: "INGRESS", action: "allow",
        match: v1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: ["0.0.0.0/0"],
          layer4_configs: [v1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "tcp", ports: ["22"])],
        ),
        target_secure_tags: [v1::FirewallPolicyRuleSecureTag.new(name: tag_value)],
      )
      policy = v1::FirewallPolicy.new(rules: [existing])
      expect(nfp_client).to receive(:get).and_return(policy)
      desired = [{
        direction: "INGRESS", source_ranges: ["0.0.0.0/0"],
        target_secure_tags: [tag_value],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }]

      expect(nfp_client).not_to receive(:add_rule)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:sync_tag_policy_rules, desired, tag_value)
    end

    it "does not count rules being deleted as used priorities" do
      stale_rule = v1::FirewallPolicyRule.new(
        priority: 10000, direction: "INGRESS", action: "allow",
        match: v1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: ["10.0.0.0/8"],
          layer4_configs: [v1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "tcp", ports: ["80"])],
        ),
        target_secure_tags: [v1::FirewallPolicyRuleSecureTag.new(name: tag_value)],
      )
      policy = v1::FirewallPolicy.new(rules: [stale_rule])
      expect(nfp_client).to receive(:get).and_return(policy)
      desired = [{
        direction: "INGRESS", source_ranges: ["0.0.0.0/0"],
        target_secure_tags: [tag_value],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }]
      expect(nfp_client).to receive(:remove_rule).with(hash_including(priority: 10000)).and_return(lro_op)
      expect(nfp_client).to receive(:add_rule) do |args|
        expect(args[:firewall_policy_rule_resource].priority).to eq(10000)
        lro_op
      end

      nx.send(:sync_tag_policy_rules, desired, tag_value)
    end

    it "ignores rules for other tag values" do
      other_tag_rule = v1::FirewallPolicyRule.new(
        priority: 10000, direction: "INGRESS", action: "allow",
        match: v1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: ["0.0.0.0/0"],
          layer4_configs: [v1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "tcp", ports: ["22"])],
        ),
        target_secure_tags: [v1::FirewallPolicyRuleSecureTag.new(name: "tagValues/other-tv")],
      )
      policy = v1::FirewallPolicy.new(rules: [other_tag_rule])
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:sync_tag_policy_rules, [], tag_value)
    end
  end

  describe "create_tag_policy_rule" do
    let(:desired) {
      {
        priority: 10000, direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: ["tagValues/tv-1"],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }
    }

    it "creates rule via add_rule" do
      expect(nfp_client).to receive(:add_rule).and_return(lro_op)
      nx.send(:create_tag_policy_rule, desired)
    end

    it "retries on priority collision (AlreadyExists)" do
      policy = v1::FirewallPolicy.new(
        rules: [v1::FirewallPolicyRule.new(priority: 10000)],
      )
      expect(nfp_client).to receive(:add_rule).ordered
        .and_raise(Google::Cloud::AlreadyExistsError.new("exists"))
      expect(Clog).to receive(:emit).with("GCP firewall priority collision, retrying with new priority", anything).and_call_original
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).to receive(:add_rule).ordered.and_return(lro_op)

      nx.send(:create_tag_policy_rule, desired)
      expect(desired[:priority]).to eq(10001)
    end

    it "retries on InvalidArgumentError with 'same priorities'" do
      policy = v1::FirewallPolicy.new(
        rules: [v1::FirewallPolicyRule.new(priority: 10000)],
      )
      expect(nfp_client).to receive(:add_rule).ordered
        .and_raise(Google::Cloud::InvalidArgumentError.new("same priorities"))
      expect(Clog).to receive(:emit).with("GCP firewall priority collision, retrying with new priority", anything).and_call_original
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).to receive(:add_rule).ordered.and_return(lro_op)

      nx.send(:create_tag_policy_rule, desired)
      expect(desired[:priority]).to eq(10001)
    end

    it "re-raises InvalidArgumentError not about priorities" do
      expect(nfp_client).to receive(:add_rule).and_raise(Google::Cloud::InvalidArgumentError.new("invalid field"))

      expect { nx.send(:create_tag_policy_rule, desired) }.to raise_error(Google::Cloud::InvalidArgumentError)
    end

    it "starts the retry scan past the collided priority, not at TAG_RULE_BASE_PRIORITY" do
      # policy has 10000 free and 10011 taken; the collided priority is 10010.
      # If we rescanned from TAG_RULE_BASE_PRIORITY we would pick 10000; starting
      # past desired[:priority] instead picks 10012.
      policy = v1::FirewallPolicy.new(
        rules: [
          v1::FirewallPolicyRule.new(priority: 10010),
          v1::FirewallPolicyRule.new(priority: 10011),
        ],
      )
      desired[:priority] = 10010

      expect(nfp_client).to receive(:add_rule).ordered.and_raise(Google::Cloud::AlreadyExistsError.new("exists"))
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).to receive(:add_rule).ordered.and_return(lro_op)

      nx.send(:create_tag_policy_rule, desired)
      expect(desired[:priority]).to eq(10012)
    end

    it "raises after 5 collision retries" do
      policy = v1::FirewallPolicy.new(
        rules: (10000..10010).map { |p| v1::FirewallPolicyRule.new(priority: p) },
      )
      expect(nfp_client).to receive(:add_rule).exactly(6).times
        .and_raise(Google::Cloud::AlreadyExistsError.new("exists"))
      expect(nfp_client).to receive(:get).exactly(5).times.and_return(policy)

      expect { nx.send(:create_tag_policy_rule, desired) }.to raise_error(Google::Cloud::AlreadyExistsError)
    end

    it "raises when all slots to 65535 are exhausted" do
      policy = v1::FirewallPolicy.new(
        rules: (65531..65535).map { |p| v1::FirewallPolicyRule.new(priority: p) },
      )
      desired[:priority] = 65530
      expect(nfp_client).to receive(:add_rule).and_raise(Google::Cloud::AlreadyExistsError.new("exists"))
      expect(nfp_client).to receive(:get).and_return(policy)

      expect { nx.send(:create_tag_policy_rule, desired) }
        .to raise_error(RuntimeError, /No available firewall policy priority slot/)
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
    it "groups by CIDR and protocol" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23), protocol: "tcp"),
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(443...444), protocol: "tcp"),
      ]
      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(1)
      expect(result.first[:layer4_configs].first[:ports]).to contain_exactly("22", "443")
    end

    it "omits :ports when any rule has nil port_range" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: nil, protocol: "tcp"),
      ]
      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.first[:layer4_configs].first).not_to have_key(:ports)
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
