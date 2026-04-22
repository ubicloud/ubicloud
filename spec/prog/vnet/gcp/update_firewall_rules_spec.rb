# frozen_string_literal: true

require "google/cloud/compute/v1"
require "google/apis/cloudresourcemanager_v3"

RSpec.describe Prog::Vnet::Gcp::UpdateFirewallRules do
  subject(:nx) { described_class.new(st) }

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
    vpc = GcpVpc.create(
      project_id: project.id,
      location_id: location.id,
      name: vpc_name,
      network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/1234567890",
    )
    Strand.create_with_id(vpc, prog: "Vnet::Gcp::VpcNexus", label: "wait")
    vpc
  }

  let(:vm) {
    location_credential
    gcp_vpc
    v = Prog::Vm::Nexus.assemble_with_sshable(project.id,
      location_id: location.id, unix_user: "test-user",
      boot_image: "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64",
      name: "testvm", size: "c4a-standard-8", arch: "arm64").subject
    DB[:private_subnet_gcp_vpc].insert(private_subnet_id: v.nics.first.private_subnet.id, gcp_vpc_id: gcp_vpc.id)
    v
  }

  let(:ps) { vm.nics.first.private_subnet }
  let(:nic) { vm.nics.first }
  let(:firewall) { ps.firewalls.first }

  # UpdateFirewallRules runs as a child of Vm::Gcp::Nexus (pushed from
  # prog/vm/gcp/nexus.rb), so production has a two-frame stack:
  #   stack[0] = UpdateFirewallRules child frame (subject_id + link)
  #   stack[-1] = Vm::Gcp::Nexus parent frame (holds gcp_zone_suffix, etc.)
  # subject_is :vm resolves @subject_id from strand.id, so we reuse vm.strand.
  let(:st) {
    child_frame = {"subject_id" => vm.id, "link" => ["Vm::Gcp::Nexus", "wait_sshable"]}
    vm.strand.update(
      prog: "Vnet::Gcp::UpdateFirewallRules",
      label: "update_firewall_rules",
      stack: Sequel.pg_jsonb_wrap([child_frame] + vm.strand.stack),
    )
    vm.strand
  }

  let(:nfp_client) { instance_double(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client) }
  let(:compute_client) { instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client) }
  let(:crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }
  let(:regional_crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }

  let(:lro_op) { instance_double(Gapic::GenericLRO::Operation, name: "op-12345") }

  let(:fw_tag_key_name) { "tagKeys/fw-123" }
  let(:fw_tag_value_name) { "tagValues/fw-tv-1" }
  let(:subnet_tag_key_name) { "tagKeys/subnet-123" }
  let(:subnet_tag_value_name) { "tagValues/subnet-tv-1" }

  let(:crm_done_op) {
    instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
      done?: true, name: "crm-op-1", response: {"name" => "tagKeys/created-1"}, error: nil)
  }
  let(:instance_obj) { Google::Cloud::Compute::V1::Instance.new(name: vm.name, id: 9876543210) }
  let(:project_obj) { Google::Apis::CloudresourcemanagerV3::Project.new(name: "projects/73189733048") }

  before do
    allow(nx.send(:credential)).to receive_messages(
      network_firewall_policies_client: nfp_client,
      compute_client:,
      crm_client:,
    )
    allow(nx.send(:credential)).to receive(:regional_crm_client).and_return(regional_crm_client)
    allow(crm_client).to receive(:get_project).and_return(project_obj)
    allow(compute_client).to receive(:get).and_return(instance_obj)
  end

  describe "#before_run" do
    it "pops if vm is being destroyed" do
      vm.incr_destroy
      expect { nx.before_run }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "does nothing if vm is not being destroyed" do
      expect { nx.before_run }.not_to exit
    end
  end

  describe "#update_firewall_rules" do
    let!(:fw_rule) {
      # SubnetNexus.assemble seeds the default firewall with permit-all rules
      # for 0.0.0.0/0 and ::/0. Clear them so each test controls its own rule set.
      firewall.firewall_rules.each(&:destroy)
      FirewallRule.create(firewall_id: firewall.id,
        cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23))
    }

    before do
      tv_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "crm-op-tv", response: {"name" => fw_tag_value_name}, error: nil)

      empty_policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      allow(nfp_client).to receive_messages(get: empty_policy, add_rule: lro_op)

      subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-subnet-#{ps.ubid}", name: subnet_tag_key_name)
      subnet_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue,
        short_name: "member", name: subnet_tag_value_name)
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [subnet_tk])
      tv_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [subnet_tv])
      allow(crm_client).to receive_messages(
        create_tag_key: crm_done_op,
        get_operation: crm_done_op,
        create_tag_value: tv_op,
        list_tag_keys: tk_list,
        list_tag_values: tv_list,
      )

      empty_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse, tag_bindings: [])
      binding_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      allow(regional_crm_client).to receive_messages(list_tag_bindings: empty_bindings, create_tag_binding: binding_op)
    end

    it "creates per-firewall tag key, tag value, syncs rules, binds tags, and pops" do
      expect(crm_client).to receive(:create_tag_key) do |tag_key|
        expect(tag_key.short_name).to eq("ubicloud-fw-#{firewall.ubid}")
        expect(tag_key.purpose).to eq("GCE_FIREWALL")
        expect(tag_key.purpose_data["network"]).to include("networks/1234567890")
        expect(tag_key.description).not_to include("e2e_run_id=")
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

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "stamps tag key and tag value descriptions with e2e_run_id when E2E_RUN_ID is set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("E2E_RUN_ID").and_return("8080")
      tv_op_local = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "crm-op-tv", response: {"name" => fw_tag_value_name}, error: nil)

      expect(crm_client).to receive(:create_tag_key) do |tag_key|
        expect(tag_key.description).to include("[e2e_run_id=8080]")
        crm_done_op
      end
      expect(crm_client).to receive(:create_tag_value) do |tag_value|
        expect(tag_value.description).to include("[e2e_run_id=8080]")
        tv_op_local
      end

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "uses fw_tag_data cache on re-entry after nap and skips tag creation" do
      refresh_frame(nx, new_values: {"fw_tag_data" => {firewall.ubid => "tagValues/cached-tv"}})

      expect(crm_client).not_to receive(:create_tag_key)
      expect(crm_client).not_to receive(:create_tag_value)

      expect(regional_crm_client).to receive(:create_tag_binding).twice

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "syncs empty rules for firewall with no rules and does not bind its tag" do
      fw_rule.destroy

      expect(crm_client).to receive(:create_tag_key)
      expect(crm_client).to receive(:create_tag_value)
      expect(nfp_client).to receive(:get).and_return(Google::Cloud::Compute::V1::FirewallPolicy.new(rules: []))
      expect(nfp_client).not_to receive(:add_rule)

      # Only subnet tag should be bound (firewall has no rules → not bound)
      expect(regional_crm_client).to receive(:create_tag_binding).once

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "handles multiple firewalls with separate tag keys" do
      firewall2 = Firewall.create(name: "fw2", location_id: location.id, project_id: project.id)
      firewall2.associate_with_private_subnet(ps, apply_firewalls: false)
      FirewallRule.create(firewall_id: firewall2.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(443...444))

      created_keys = []
      expect(crm_client).to receive(:create_tag_key).twice do |tag_key|
        created_keys << tag_key.short_name
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
          done?: true, name: "crm-op", response: {"name" => "tagKeys/#{tag_key.short_name}"}, error: nil)
      end

      expect(crm_client).to receive(:create_tag_value).twice do |tag_value|
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
          done?: true, name: "crm-op-tv", response: {"name" => "tagValues/#{tag_value.parent}"}, error: nil)
      end

      expect(nfp_client).to receive(:add_rule).twice.and_return(lro_op)
      # 2 firewall tags + 1 subnet tag
      expect(regional_crm_client).to receive(:create_tag_binding).exactly(3).times

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
      expect(created_keys).to contain_exactly("ubicloud-fw-#{firewall.ubid}", "ubicloud-fw-#{firewall2.ubid}")
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
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      # Should not unbind the active one or the subnet one
      expect(regional_crm_client).not_to receive(:delete_tag_binding).with("tagBindings/active-1")

      # Subnet tag still needs to be bound
      expect(regional_crm_client).to receive(:create_tag_binding).once

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "creates new tag bindings before deleting stale ones" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value: "tagValues/old-fw-tv")

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])

      unbind_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "unbind-op", error: nil)
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      call_order = []
      expect(regional_crm_client).to receive(:create_tag_binding).twice do |binding|
        call_order << :create
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      end
      expect(regional_crm_client).to receive(:delete_tag_binding).once do |name|
        call_order << :delete
        unbind_op
      end

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")

      last_create = call_order.rindex(:create)
      first_delete = call_order.index(:delete)
      expect(last_create).not_to be_nil
      expect(first_delete).not_to be_nil
      expect(last_create).to be < first_delete
    end

    it "hops to wait_tag_binding_deletes when NIC tag limit hit and stale bindings exist" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value: "tagValues/old-fw-tv")

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      unbind_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: false, name: "operations/unbind-1", error: nil)

      # The subnet tag create succeeds; the firewall tag create hits the limit.
      # create_tag_binding is called for both; only the fw one is queued for retry.
      expect(regional_crm_client).to receive(:create_tag_binding).twice do |binding|
        if binding.tag_value == fw_tag_value_name
          raise Google::Apis::ClientError.new("tag limit exceeded", status_code: 400)
        end
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      end
      expect(regional_crm_client).to receive(:delete_tag_binding).with("tagBindings/stale-1").and_return(unbind_op)

      expect { nx.update_firewall_rules }.to hop("wait_tag_binding_deletes")

      stashed = st.reload.stack.first
      expect(stashed["pending_tag_binding_deletes"]).to eq(["operations/unbind-1"])
      expect(stashed["failed_creates_to_retry"]).to eq([fw_tag_value_name])
    end

    it "re-raises non-404 delete errors on the retry path without hopping" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-denied", tag_value: "tagValues/old-tv")

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      expect(regional_crm_client).to receive(:create_tag_binding).twice do |binding|
        if binding.tag_value == fw_tag_value_name
          raise Google::Apis::ClientError.new("tag limit exceeded", status_code: 400)
        end
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      end
      expect(regional_crm_client).to receive(:delete_tag_binding).with("tagBindings/stale-denied")
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.update_firewall_rules }.to raise_error(Google::Apis::ClientError, /forbidden/)

      # The frame must not be stashed when we bail out on a non-404 delete error.
      stashed = st.reload.stack.first
      expect(stashed["pending_tag_binding_deletes"]).to be_nil
      expect(stashed["failed_creates_to_retry"]).to be_nil
    end

    it "filters 404 deletes out of pending_tag_binding_deletes on the retry path" do
      stale_binding_404 = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/gone-1", tag_value: "tagValues/gone-tv")
      stale_binding_ok = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-2", tag_value: "tagValues/old-tv")

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding_404, stale_binding_ok])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      unbind_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: false, name: "operations/unbind-ok", error: nil)

      expect(regional_crm_client).to receive(:create_tag_binding).twice do |binding|
        if binding.tag_value == fw_tag_value_name
          raise Google::Apis::ClientError.new("tag limit exceeded", status_code: 400)
        end
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      end
      expect(regional_crm_client).to receive(:delete_tag_binding).with("tagBindings/gone-1")
        .and_raise(Google::Apis::ClientError.new("not found", status_code: 404))
      expect(regional_crm_client).to receive(:delete_tag_binding).with("tagBindings/stale-2").and_return(unbind_op)

      expect { nx.update_firewall_rules }.to hop("wait_tag_binding_deletes")

      stashed = st.reload.stack.first
      expect(stashed["pending_tag_binding_deletes"]).to eq(["operations/unbind-ok"])
      expect(stashed["failed_creates_to_retry"]).to eq([fw_tag_value_name])
    end

    it "re-raises non-400 ClientErrors from create_tag_binding" do
      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      expect(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.update_firewall_rules }.to raise_error(Google::Apis::ClientError, /forbidden/)
    end

    it "naps when create 400s, no stale bindings, and re-read confirms binding absent" do
      active_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/active-1", tag_value: fw_tag_value_name)

      initial_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [active_binding])
      reread_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [active_binding])

      # First list = initial desired/existing diff; second list = re-read after 400
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(initial_list, reread_list)

      expect(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("bad request", status_code: 400))

      expect(regional_crm_client).not_to receive(:delete_tag_binding)
      expect(Clog).to receive(:emit)
        .with("Tag binding 400 with binding not present, napping for retry",
          hash_including(:tag_value, :parent))
        .and_call_original

      expect { nx.update_firewall_rules }.to nap(5)
    end

    it "naps when create 400s and the re-read returns nil tag_bindings" do
      active_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/active-1", tag_value: fw_tag_value_name)

      initial_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [active_binding])
      reread_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: nil)

      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(initial_list, reread_list)

      expect(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("bad request", status_code: 400))

      expect(Clog).to receive(:emit)
        .with("Tag binding 400 with binding not present, napping for retry",
          hash_including(:tag_value, :parent))
        .and_call_original

      expect { nx.update_firewall_rules }.to nap(5)
    end

    it "proceeds when create 400s but re-read shows the binding actually landed" do
      active_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/active-1", tag_value: fw_tag_value_name)
      landed_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/landed-1", tag_value: subnet_tag_value_name)

      initial_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [active_binding])
      reread_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [active_binding, landed_binding])

      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(initial_list, reread_list)

      # The one create for subnet_tag_value_name 400s; re-read shows it present
      expect(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("bad request", status_code: 400))

      # No nap - we proceed through the loop
      expect(Clog).not_to receive(:emit).with("Tag binding 400 with binding not present, napping for retry", anything)

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "handles subnet tag not found gracefully" do
      no_subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [])
      expect(crm_client).to receive(:list_tag_keys).and_return(no_subnet_tk)

      expect(regional_crm_client).to receive(:create_tag_binding).once

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "truncates desired tags and logs when exceeding GCP 10-tag NIC limit" do
      # Need 11 firewalls total. The first is already attached. Bypass the
      # GCP_MAX_FIREWALLS_PER_VM=9 validation by inserting join rows directly.
      extra_firewalls = (2..11).map { |i|
        fw = Firewall.create(name: "fw#{i}", location_id: location.id, project_id: project.id)
        FirewallRule.create(firewall_id: fw.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23))
        DB[:firewalls_private_subnets].insert(private_subnet_id: ps.id, firewall_id: fw.id)
        fw
      }
      all_firewalls = [firewall] + extra_firewalls

      # ensure_firewall_tag_key / ensure_tag_value run once per attached firewall
      # before truncation, so all 11 firewalls drive create_tag_key / create_tag_value.
      expect(crm_client).to receive(:create_tag_key).exactly(11).times do |tag_key|
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
          done?: true, name: "crm-op", response: {"name" => "tagKeys/#{tag_key.short_name}"}, error: nil)
      end
      expect(crm_client).to receive(:create_tag_value).exactly(11).times do |tag_value|
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
          done?: true, name: "crm-op-tv", response: {"name" => "tagValues/#{tag_value.parent}-active"}, error: nil)
      end

      empty_policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      expect(nfp_client).to receive_messages(get: empty_policy, add_rule: lro_op)

      # 12 desired (11 fw + 1 subnet) → truncated to 10 (9 fw + 1 subnet)
      bound_tags = []
      expect(regional_crm_client).to receive(:create_tag_binding).exactly(10).times do |binding|
        bound_tags << binding.tag_value
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      end

      expect(Clog).to receive(:emit).with("GCP NIC tag limit exceeded, truncating to 10", anything).and_call_original

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
      expect(bound_tags).to include(subnet_tag_value_name)
      expect(bound_tags.size).to eq(10)
      expect(all_firewalls.size).to eq(11)
    end

    it "truncates to 10 without subnet tag when subnet tag is not found" do
      (2..11).each do |i|
        fw = Firewall.create(name: "fw#{i}", location_id: location.id, project_id: project.id)
        FirewallRule.create(firewall_id: fw.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23))
        DB[:firewalls_private_subnets].insert(private_subnet_id: ps.id, firewall_id: fw.id)
      end

      # 11 firewalls (1 pre-existing + 10 extras) each drive a tag_key + tag_value create.
      expect(crm_client).to receive(:create_tag_key).exactly(11).times do |tag_key|
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
          done?: true, name: "crm-op", response: {"name" => "tagKeys/#{tag_key.short_name}"}, error: nil)
      end
      expect(crm_client).to receive(:create_tag_value).exactly(11).times do |tag_value|
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
          done?: true, name: "crm-op-tv", response: {"name" => "tagValues/#{tag_value.parent}-active"}, error: nil)
      end

      no_subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [])
      expect(crm_client).to receive(:list_tag_keys).and_return(no_subnet_tk)

      empty_policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      expect(nfp_client).to receive_messages(get: empty_policy, add_rule: lro_op)

      expect(regional_crm_client).to receive(:create_tag_binding).exactly(10).times

      expect(Clog).to receive(:emit).with("GCP NIC tag limit exceeded, truncating to 10", anything).and_call_original

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "skips already-bound tags" do
      existing_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/existing-1", tag_value: fw_tag_value_name)
      subnet_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/existing-2", tag_value: subnet_tag_value_name)

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [existing_binding, subnet_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      expect(regional_crm_client).not_to receive(:create_tag_binding)
      expect(regional_crm_client).not_to receive(:delete_tag_binding)

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "handles unbind 404 gracefully" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value: "tagValues/old")

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      expect(regional_crm_client).to receive(:delete_tag_binding)
        .and_raise(Google::Apis::ClientError.new("not found", status_code: 404))

      expect(regional_crm_client).to receive(:create_tag_binding).twice

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "re-raises non-404 errors during stale binding unbind" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value: "tagValues/old")

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      expect(regional_crm_client).to receive(:delete_tag_binding)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.update_firewall_rules }.to raise_error(Google::Apis::ClientError, /forbidden/)
    end

    it "re-entering update_firewall_rules after the wait label completes pops via the link" do
      # Simulates the state immediately after wait_tag_binding_deletes hopped
      # back: fw_tag_data cached, frame keys cleared, bindings converged.
      refresh_frame(nx, new_values: {"fw_tag_data" => {firewall.ubid => fw_tag_value_name}})

      fw_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/fw-1", tag_value: fw_tag_value_name)
      subnet_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/subnet-1", tag_value: subnet_tag_value_name)
      converged = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [fw_binding, subnet_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(converged)

      expect(crm_client).not_to receive(:create_tag_key)
      expect(crm_client).not_to receive(:create_tag_value)
      expect(regional_crm_client).not_to receive(:create_tag_binding)
      expect(regional_crm_client).not_to receive(:delete_tag_binding)

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end
  end

  describe "#wait_tag_binding_deletes" do
    it "retries failed creates and hops to update_firewall_rules when all deletes are done" do
      refresh_frame(nx, new_values: {
        "pending_tag_binding_deletes" => ["operations/op-1", "operations/op-2"],
        "failed_creates_to_retry" => ["tagValues/retry-1", "tagValues/retry-2"],
      })

      done_1 = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "operations/op-1", error: nil)
      done_2 = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "operations/op-2", error: nil)
      expect(regional_crm_client).to receive(:get_operation).with("operations/op-1").and_return(done_1)
      expect(regional_crm_client).to receive(:get_operation).with("operations/op-2").and_return(done_2)

      retried = []
      bind_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      expect(regional_crm_client).to receive(:create_tag_binding).twice do |binding|
        retried << binding.tag_value
        bind_op
      end

      expect { nx.wait_tag_binding_deletes }.to hop("update_firewall_rules")
      expect(retried).to eq(["tagValues/retry-1", "tagValues/retry-2"])

      cleared = st.reload.stack.first
      expect(cleared["pending_tag_binding_deletes"]).to be_nil
      expect(cleared["failed_creates_to_retry"]).to be_nil
    end

    it "naps while any delete operation is not done" do
      refresh_frame(nx, new_values: {
        "pending_tag_binding_deletes" => ["operations/op-a", "operations/op-b"],
        "failed_creates_to_retry" => ["tagValues/retry-1"],
      })

      done_a = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "operations/op-a", error: nil)
      pending_b = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: false, name: "operations/op-b")
      expect(regional_crm_client).to receive(:get_operation).with("operations/op-a").and_return(done_a)
      expect(regional_crm_client).to receive(:get_operation).with("operations/op-b").and_return(pending_b)
      expect(regional_crm_client).not_to receive(:create_tag_binding)

      expect { nx.wait_tag_binding_deletes }.to nap(5)

      # Frame must remain intact so the next re-entry re-polls.
      stashed = st.reload.stack.first
      expect(stashed["pending_tag_binding_deletes"]).to eq(["operations/op-a", "operations/op-b"])
      expect(stashed["failed_creates_to_retry"]).to eq(["tagValues/retry-1"])
    end

    it "raises CrmOperationError when a delete operation surfaces an error" do
      refresh_frame(nx, new_values: {
        "pending_tag_binding_deletes" => ["operations/op-err"],
        "failed_creates_to_retry" => ["tagValues/retry-1"],
      })

      error_status = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 7, message: "PERMISSION_DENIED: cannot delete")
      err_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/op-err", error: error_status)
      expect(regional_crm_client).to receive(:get_operation).with("operations/op-err").and_return(err_op)
      expect(regional_crm_client).not_to receive(:create_tag_binding)

      expect { nx.wait_tag_binding_deletes }
        .to raise_error(described_class::CrmOperationError, /PERMISSION_DENIED/) { |e| expect(e.code).to eq(7) }
    end

    it "tolerates missing frame keys (defensive nil handling) and hops back" do
      # The hop from sync_tag_bindings always stashes both keys, so this
      # path is purely defensive against a manually-rehydrated frame.
      expect(regional_crm_client).not_to receive(:get_operation)
      expect(regional_crm_client).not_to receive(:create_tag_binding)

      expect { nx.wait_tag_binding_deletes }.to hop("update_firewall_rules")
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

      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-fw-#{firewall.ubid}", name: "tagKeys/lookup-1")
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

      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-fw-#{firewall.ubid}", name: "tagKeys/existing-1")
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

    it "naps again when polling pending operation that is still not done" do
      refresh_frame(nx, new_values: {
        "pending_tag_key_crm_op" => "operations/still-pending",
        "pending_tag_key_fw_ubid" => firewall.ubid,
      })

      still_pending = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: false)
      expect(crm_client).to receive(:get_operation).with("operations/still-pending").and_return(still_pending)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to nap(5)
    end

    it "falls back to lookup when polled op has no name in response" do
      refresh_frame(nx, new_values: {
        "pending_tag_key_crm_op" => "operations/no-name",
        "pending_tag_key_fw_ubid" => firewall.ubid,
      })

      no_name_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/no-name", response: nil, error: nil)
      expect(crm_client).to receive(:get_operation).with("operations/no-name").and_return(no_name_op)

      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-fw-#{firewall.ubid}", name: "tagKeys/fallback-poll")
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [tk])
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      result = nx.send(:ensure_firewall_tag_key, firewall)
      expect(result).to eq("tagKeys/fallback-poll")
    end

    it "raises when polled pending op has error" do
      refresh_frame(nx, new_values: {
        "pending_tag_key_crm_op" => "operations/tk-error",
        "pending_tag_key_fw_ubid" => firewall.ubid,
      })

      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 13, message: "INTERNAL: server error")
      error_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/tk-error", error:)
      expect(crm_client).to receive(:get_operation).with("operations/tk-error").and_return(error_op)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to raise_error(described_class::CrmOperationError, /INTERNAL/) { |e| expect(e.code).to eq(13) }
    end

    it "handles ALREADY_EXISTS from CRM LRO by looking up existing key" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 6, message: "tag key already exists")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-fw-#{firewall.ubid}", name: "tagKeys/existing-lro-1")
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [tk])
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      result = nx.send(:ensure_firewall_tag_key, firewall)
      expect(result).to eq("tagKeys/existing-lro-1")
    end

    it "raises on ALREADY_EXISTS from LRO when lookup returns nothing" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 6, message: "tag key already exists")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: nil)
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to raise_error(/conflict but not found/)
    end

    it "re-raises non-ALREADY_EXISTS LRO errors" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 7, message: "PERMISSION_DENIED: access denied")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_key).and_return(op)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to raise_error(described_class::CrmOperationError, /PERMISSION_DENIED/) { |e| expect(e.code).to eq(7) }
    end

    it "ignores pending op from a different firewall and creates fresh" do
      refresh_frame(nx, new_values: {
        "pending_tag_key_crm_op" => "operations/other-fw",
        "pending_tag_key_fw_ubid" => "fwubid-other",
      })

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
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 6, message: "tag value already exists")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_value).and_return(op)

      tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: "tagValues/existing-lro-1")
      tv_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [tv])
      expect(crm_client).to receive(:list_tag_values).and_return(tv_list)

      result = nx.send(:ensure_tag_value, "tagKeys/123", "active")
      expect(result).to eq("tagValues/existing-lro-1")
    end

    it "re-raises non-ALREADY_EXISTS LRO errors for tag value" do
      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 7, message: "PERMISSION_DENIED: access denied")
      op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "op-1", error:)
      expect(crm_client).to receive(:create_tag_value).and_return(op)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(described_class::CrmOperationError, /PERMISSION_DENIED/) { |e| expect(e.code).to eq(7) }
    end

    it "naps when CRM operation is not done and saves op name in frame" do
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

      result = nx.send(:ensure_tag_value, "tagKeys/123", "active")
      expect(result).to eq("tagValues/polled-1")
      expect(st.reload.stack.first["pending_tag_value_crm_op"]).to be_nil
    end

    it "naps again when polling pending tag value op that is still not done" do
      refresh_frame(nx, new_values: {
        "pending_tag_value_crm_op" => "operations/tv-still-pending",
        "pending_tag_value_parent" => "tagKeys/123",
      })

      still_pending = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: false)
      expect(crm_client).to receive(:get_operation).with("operations/tv-still-pending").and_return(still_pending)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to nap(5)
    end

    it "falls back to lookup when polled tag value op has no name in response" do
      refresh_frame(nx, new_values: {
        "pending_tag_value_crm_op" => "operations/tv-no-name",
        "pending_tag_value_parent" => "tagKeys/123",
      })

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
      refresh_frame(nx, new_values: {
        "pending_tag_value_crm_op" => "operations/tv-error",
        "pending_tag_value_parent" => "tagKeys/123",
      })

      error = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 13, message: "INTERNAL: server error")
      error_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/tv-error", error:)
      expect(crm_client).to receive(:get_operation).with("operations/tv-error").and_return(error_op)

      expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(described_class::CrmOperationError, /INTERNAL/) { |e| expect(e.code).to eq(13) }
    end

    it "ignores pending op from a different parent and creates fresh" do
      refresh_frame(nx, new_values: {
        "pending_tag_value_crm_op" => "operations/other-parent",
        "pending_tag_value_parent" => "tagKeys/999",
      })

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
      expect(Clog).to receive(:emit).with("GCP firewall priority collision, retrying with new priority", anything).and_call_original
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
      expect(Clog).to receive(:emit).with("GCP firewall priority collision, retrying with new priority", anything).and_call_original
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

    it "raises if the next free priority would exceed 65535" do
      desired = {
        priority: 65530,
        direction: "INGRESS",
        source_ranges: ["0.0.0.0/0"],
        target_secure_tags: ["tagValues/tv-1"],
        layer4_configs: [{ip_protocol: "tcp", ports: ["22"]}],
      }

      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(
        rules: (65531..65535).map { |p| Google::Cloud::Compute::V1::FirewallPolicyRule.new(priority: p) },
      )

      expect(nfp_client).to receive(:add_rule).and_raise(Google::Cloud::AlreadyExistsError.new("exists"))
      expect(nfp_client).to receive(:get).with(project: "test-gcp-project", firewall_policy: vpc_name).and_return(policy)

      expect { nx.send(:create_tag_policy_rule, desired) }
        .to raise_error(RuntimeError, /No available firewall policy priority slot/)
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
      expect(Clog).to receive(:emit).with("GCP firewall priority collision, retrying with new priority", anything).exactly(5).times.and_call_original
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
      nx.send(:delete_policy_rule, 10000)
    end

    it "handles InvalidArgumentError" do
      expect(nfp_client).to receive(:remove_rule)
        .and_raise(Google::Cloud::InvalidArgumentError.new("invalid"))
      nx.send(:delete_policy_rule, 10000)
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

      nx.send(:create_tag_binding, "//compute.googleapis.com/...", "tagValues/tv-1")
    end

    it "re-raises non-409 non-400 errors" do
      expect(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.send(:create_tag_binding, "//compute.googleapis.com/...", "tagValues/tv-1") }.to raise_error(Google::Apis::ClientError)
    end

    it "re-raises 400 errors" do
      expect(regional_crm_client).to receive(:create_tag_binding)
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

  describe "cleanup_orphaned_firewall_rules" do
    let(:orphan_fw) { Firewall.create(name: "orphan-fw", location_id: location.id, project_id: project.id) }
    let(:orphan_fw_ubid) { orphan_fw.ubid }
    let(:orphan_tag_key_name) { "tagKeys/orphan-123" }
    let(:orphan_tag_value_name) { "tagValues/orphan-tv-1" }
    let(:vpc_purpose_data) { {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/1234567890"} }

    it "deletes policy rules, tag value, and tag key for firewalls with no subnets" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)
      active_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{firewall.ubid}", name: fw_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk, active_tk]))

      orphan_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: orphan_tag_value_name)
      expect(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [orphan_tv]))

      orphan_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10005,
        action: "allow",
        target_secure_tags: [Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: orphan_tag_value_name)],
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [orphan_rule])
      expect(nfp_client).to receive(:get).and_return(policy)

      expect(nfp_client).to receive(:remove_rule).with(hash_including(priority: 10005)).and_return(lro_op)
      expect(crm_client).to receive(:delete_tag_value).with(orphan_tag_value_name).and_return(crm_done_op)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name).and_return(crm_done_op)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "deletes policy rules, tag value, and tag key for deleted firewalls (not found in DB)" do
      deleted_fw_ubid = Firewall.generate_ubid.to_s
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{deleted_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk]))

      orphan_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: orphan_tag_value_name)
      expect(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [orphan_tv]))

      orphan_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10010,
        action: "allow",
        target_secure_tags: [Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: orphan_tag_value_name)],
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [orphan_rule])
      expect(nfp_client).to receive(:get).and_return(policy)

      expect(nfp_client).to receive(:remove_rule).with(hash_including(priority: 10010)).and_return(lro_op)
      expect(crm_client).to receive(:delete_tag_value).with(orphan_tag_value_name).and_return(crm_done_op)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name).and_return(crm_done_op)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips firewalls still attached to subnets" do
      # Real firewall attached to a different private subnet so it is not in
      # vm.firewalls (would be caught by the early active-set filter) but is
      # still discovered as associated via the UNION query.
      attached_fw = Firewall.create(name: "attached-fw", location_id: location.id, project_id: project.id)
      other_ps = PrivateSubnet.create(name: "other-ps", location_id: location.id,
        net6: "fd91:4ef3:a586:943d::/64", net4: "192.168.9.0/24", project_id: project.id)
      DB[:firewalls_private_subnets].insert(firewall_id: attached_fw.id, private_subnet_id: other_ps.id)

      attached_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{attached_fw.ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [attached_tk]))

      expect(nfp_client).not_to receive(:get)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips firewalls attached directly to VMs (not through subnets)" do
      # Firewall attached to some other vm via firewalls_vms. It won't show up
      # in this vm's firewalls list but must still be detected by the UNION.
      vm_fw = Firewall.create(name: "vm-attached-fw", location_id: location.id, project_id: project.id)
      other_vm_id = DB[:vm].insert(id: Sequel.function(:gen_random_uuid),
        unix_user: "x", public_key: "x", name: "other-vm", boot_image: "img",
        family: "standard", cores: 1, vcpus: 1, memory_gib: 1,
        project_id: project.id, location_id: location.id)
      DB[:firewalls_vms].insert(firewall_id: vm_fw.id, vm_id: other_vm_id)

      vm_fw_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{vm_fw.ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [vm_fw_tk]))

      expect(nfp_client).not_to receive(:get)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips active firewalls (attached to this VM)" do
      active_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{firewall.ubid}", name: fw_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [active_tk]))

      expect(nfp_client).not_to receive(:get)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips non-GCE_FIREWALL tag keys" do
      non_fw_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-someubid", name: "tagKeys/other-1", purpose: nil)

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [non_fw_tk]))

      expect(nfp_client).not_to receive(:get)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips tag keys without matching short_name prefix" do
      subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-subnet-#{ps.ubid}", name: "tagKeys/subnet-1", purpose: "GCE_FIREWALL")

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [subnet_tk]))

      expect(nfp_client).not_to receive(:get)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "returns early when no tag keys exist" do
      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: nil))

      expect(nfp_client).not_to receive(:get)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips tag keys from other VPCs" do
      other_vpc_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL",
        purpose_data: {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/9999999999"})

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [other_vpc_tk]))

      expect(nfp_client).not_to receive(:get)
      expect(crm_client).not_to receive(:delete_tag_key)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips tag keys with nil purpose_data" do
      nil_pd_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL",
        purpose_data: nil)

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [nil_pd_tk]))

      expect(nfp_client).not_to receive(:get)
      expect(crm_client).not_to receive(:delete_tag_key)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "deletes tag key even when no tag value exists" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk]))

      expect(crm_client).to receive(:list_tag_values)
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

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk]))

      orphan_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: orphan_tag_value_name)
      expect(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [orphan_tv]))

      deny_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10005,
        action: "deny",
        target_secure_tags: [Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: orphan_tag_value_name)],
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [deny_rule])
      expect(nfp_client).to receive(:get).and_return(policy)

      expect(nfp_client).not_to receive(:remove_rule)
      expect(crm_client).to receive(:delete_tag_value).with(orphan_tag_value_name).and_return(crm_done_op)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name).and_return(crm_done_op)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "skips allow rules whose tags do not match the orphan tag value" do
      orphan_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk]))

      orphan_tv = instance_double(Google::Apis::CloudresourcemanagerV3::TagValue, short_name: "active", name: orphan_tag_value_name)
      expect(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: [orphan_tv]))

      unrelated_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 10005,
        action: "allow",
        target_secure_tags: [Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: "tagValues/other-tv")],
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [unrelated_rule])
      expect(nfp_client).to receive(:get).and_return(policy)

      expect(nfp_client).not_to receive(:remove_rule)
      expect(crm_client).to receive(:delete_tag_value).with(orphan_tag_value_name).and_return(crm_done_op)
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name).and_return(crm_done_op)

      nx.send(:cleanup_orphaned_firewall_rules)
    end

    it "propagates errors from per-orphan cleanup" do
      orphan_tk1 = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk1]))

      expect(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.send(:cleanup_orphaned_firewall_rules) }.to raise_error(Google::Apis::ClientError, /forbidden/)
    end

    it "propagates Google::Cloud::Error from list_tag_keys" do
      expect(crm_client).to receive(:list_tag_keys)
        .and_raise(Google::Cloud::Error.new("error"))

      expect { nx.send(:cleanup_orphaned_firewall_rules) }.to raise_error(Google::Cloud::Error)
    end

    it "propagates RuntimeError from list_tag_keys during orphan cleanup" do
      expect(crm_client).to receive(:list_tag_keys)
        .and_raise(RuntimeError.new("CRM operation op-1 failed: PERMISSION_DENIED"))

      expect { nx.send(:cleanup_orphaned_firewall_rules) }.to raise_error(RuntimeError, /PERMISSION_DENIED/)
    end

    it "propagates RuntimeError from delete_tag_key during orphan cleanup" do
      orphan_tk1 = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey,
        short_name: "ubicloud-fw-#{orphan_fw_ubid}", name: orphan_tag_key_name, purpose: "GCE_FIREWALL", purpose_data: vpc_purpose_data)

      expect(crm_client).to receive(:list_tag_keys)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [orphan_tk1]))

      expect(crm_client).to receive(:list_tag_values)
        .with(parent: orphan_tag_key_name)
        .and_return(instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: nil))
      expect(crm_client).to receive(:delete_tag_key).with(orphan_tag_key_name)
        .and_raise(RuntimeError.new("CRM operation op-1 failed: Cannot delete tag key still attached to resources"))

      expect { nx.send(:cleanup_orphaned_firewall_rules) }.to raise_error(RuntimeError, /Cannot delete tag key/)
    end
  end

  describe "build_tag_based_policy_rules" do
    it "groups rules by CIDR" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23), protocol: "tcp"),
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(443...444), protocol: "tcp"),
      ]

      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(1)
      expect(result.first[:source_ranges]).to eq(["0.0.0.0/0"])
      expect(result.first[:layer4_configs].first[:ports]).to contain_exactly("22", "443")
    end

    it "creates separate rules for different CIDRs" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23), protocol: "tcp"),
        FirewallRule.create(firewall_id: firewall.id, cidr: "10.0.0.0/8", port_range: Sequel.pg_range(5432...5433), protocol: "tcp"),
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
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23), protocol: "tcp"),
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(53...54), protocol: "udp"),
      ]

      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(1)
      expect(result.first[:layer4_configs].length).to eq(2)
      protos = result.first[:layer4_configs].map { |c| c[:ip_protocol] }
      expect(protos).to contain_exactly("tcp", "udp")
    end

    it "formats port ranges correctly" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(80...9999), protocol: "tcp"),
      ]

      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.first[:layer4_configs].first[:ports]).to eq(["80-9998"])
    end

    it "formats single-port ranges as single number" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(5432...5433), protocol: "tcp"),
      ]

      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.first[:layer4_configs].first[:ports]).to eq(["5432"])
    end

    it "groups IPv6-only rules into a single policy rule" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "fd10::/64", port_range: Sequel.pg_range(80...81), protocol: "tcp"),
        FirewallRule.create(firewall_id: firewall.id, cidr: "fd10::/64", port_range: Sequel.pg_range(443...444), protocol: "tcp"),
      ]

      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(1)
      expect(result.first[:source_ranges]).to eq(["fd10::/64"])
      expect(result.first[:layer4_configs].length).to eq(1)
      expect(result.first[:layer4_configs].first[:ip_protocol]).to eq("tcp")
      expect(result.first[:layer4_configs].first[:ports]).to contain_exactly("80", "443")
    end

    it "produces separate policy rules for mixed IPv4 and IPv6 rules" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "10.0.0.0/24", port_range: Sequel.pg_range(22...23), protocol: "tcp"),
        FirewallRule.create(firewall_id: firewall.id, cidr: "fd10::/64", port_range: Sequel.pg_range(80...81), protocol: "tcp"),
      ]

      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(2)
      expect(result.map { |r| r[:source_ranges] }).to contain_exactly(["10.0.0.0/24"], ["fd10::/64"])

      v4 = result.find { |r| r[:source_ranges] == ["10.0.0.0/24"] }
      v6 = result.find { |r| r[:source_ranges] == ["fd10::/64"] }
      expect(v4[:layer4_configs]).to eq([{ip_protocol: "tcp", ports: ["22"]}])
      expect(v6[:layer4_configs]).to eq([{ip_protocol: "tcp", ports: ["80"]}])
    end

    it "omits :ports in layer4 config for an IPv6 rule with nil port_range" do
      rules = [
        FirewallRule.create(firewall_id: firewall.id, cidr: "fd10::/64", port_range: nil, protocol: "tcp"),
      ]

      result = nx.send(:build_tag_based_policy_rules, rules, tag_value_name: "tagValues/tv-1")
      expect(result.length).to eq(1)
      expect(result.first[:source_ranges]).to eq(["fd10::/64"])
      cfg = result.first[:layer4_configs].first
      expect(cfg[:ip_protocol]).to eq("tcp")
      expect(cfg).not_to have_key(:ports)
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

    it "matches when desired omits :ports entirely (unset/nil)" do
      rule = make_rule(l4: [{proto: "all", ports: nil}])
      desired = make_desired(l4: [{ip_protocol: "all"}])
      expect(nx.send(:tag_policy_rule_matches?, rule, desired)).to be true
    end

    it "returns true for an IPv6 match" do
      rule = make_rule(src_ranges: ["fd10::/64"], l4: [{proto: "tcp", ports: ["80"]}])
      desired = make_desired(source_ranges: ["fd10::/64"], l4: [{ip_protocol: "tcp", ports: ["80"]}])
      expect(nx.send(:tag_policy_rule_matches?, rule, desired)).to be true
    end

    it "returns false when existing is IPv4 but desired is IPv6" do
      rule = make_rule(src_ranges: ["10.0.0.0/8"])
      desired = make_desired(source_ranges: ["fd10::/64"])
      expect(nx.send(:tag_policy_rule_matches?, rule, desired)).to be false
    end
  end

  describe "lookup_subnet_tag_value" do
    it "returns tag value name when subnet tag exists" do
      subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-subnet-#{ps.ubid}", name: "tagKeys/subnet-1")
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
      subnet_tk = instance_double(Google::Apis::CloudresourcemanagerV3::TagKey, short_name: "ubicloud-subnet-#{ps.ubid}", name: "tagKeys/subnet-1")
      tk_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse, tag_keys: [subnet_tk])
      expect(crm_client).to receive(:list_tag_keys).and_return(tk_list)

      tv_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse, tag_values: nil)
      expect(crm_client).to receive(:list_tag_values).and_return(tv_list)

      result = nx.send(:lookup_subnet_tag_value)
      expect(result).to be_nil
    end
  end

  describe "helper methods" do
    it "defaults zone suffix to 'a'" do
      expect(nx.send(:gcp_zone)).to eq("us-central1-a")
    end

    it "finds zone suffix in parent frame" do
      refresh_frame(nx, parent_values: {"gcp_zone_suffix" => "b"})
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

  describe "strand frame shape" do
    it "writes pending-op state to child frame and reads zone suffix from parent frame" do
      refresh_frame(nx, parent_values: {"gcp_zone_suffix" => "d"})

      pending_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: false, name: "op-frame-shape")
      expect(crm_client).to receive(:create_tag_key).and_return(pending_op)

      expect { nx.send(:ensure_firewall_tag_key, firewall) }.to nap(5)

      st.reload
      expect(st.stack.length).to eq(2)
      expect(st.stack.first).not_to eq(st.stack.last)

      expect(st.stack.first["pending_tag_key_crm_op"]).to eq("op-frame-shape")
      expect(st.stack.first["pending_tag_key_fw_ubid"]).to eq(firewall.ubid)
      expect(st.stack.last).not_to have_key("pending_tag_key_crm_op")
      expect(st.stack.last).not_to have_key("pending_tag_key_fw_ubid")

      expect(st.stack.last["gcp_zone_suffix"]).to eq("d")
      expect(st.stack.first).not_to have_key("gcp_zone_suffix")
      expect(nx.send(:gcp_zone)).to eq("us-central1-d")
    end
  end

  describe "sync_firewall_rules" do
    it "partitions IPv4 and IPv6 rules and syncs" do
      ipv4_rule = FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23), protocol: "tcp")
      ipv6_rule = FirewallRule.create(firewall_id: firewall.id, cidr: "::/0", port_range: Sequel.pg_range(22...23), protocol: "tcp")

      empty_policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      expect(nfp_client).to receive(:get).and_return(empty_policy)

      expect(nfp_client).to receive(:add_rule).twice.and_return(lro_op)

      nx.send(:sync_firewall_rules, [ipv4_rule, ipv6_rule], "tagValues/tv-1")
    end

    it "emits per-family src_ip_ranges on add_rule for mixed IPv4 and IPv6 rules" do
      ipv4_rule = FirewallRule.create(firewall_id: firewall.id, cidr: "10.0.0.0/24", port_range: Sequel.pg_range(22...23), protocol: "tcp")
      ipv6_rule = FirewallRule.create(firewall_id: firewall.id, cidr: "fd10::/64", port_range: Sequel.pg_range(80...81), protocol: "tcp")

      empty_policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      expect(nfp_client).to receive(:get).and_return(empty_policy)

      captured = []
      expect(nfp_client).to receive(:add_rule).twice do |args|
        captured << args[:firewall_policy_rule_resource]
        lro_op
      end

      nx.send(:sync_firewall_rules, [ipv4_rule, ipv6_rule], "tagValues/tv-1")

      expect(captured.map { |r| r.match.src_ip_ranges.to_a })
        .to contain_exactly(["10.0.0.0/24"], ["fd10::/64"])

      v4 = captured.find { |r| r.match.src_ip_ranges.to_a == ["10.0.0.0/24"] }
      v6 = captured.find { |r| r.match.src_ip_ranges.to_a == ["fd10::/64"] }
      expect(v4.match.layer4_configs.first.ip_protocol).to eq("tcp")
      expect(v4.match.layer4_configs.first.ports.to_a).to eq(["22"])
      expect(v6.match.layer4_configs.first.ip_protocol).to eq("tcp")
      expect(v6.match.layer4_configs.first.ports.to_a).to eq(["80"])
    end

    it "treats nil port_range as all ports (no ports field in layer4 config)" do
      rule = FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: nil, protocol: "tcp")

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
      all_ports_rule = FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: nil, protocol: "tcp")
      specific_rule = FirewallRule.create(firewall_id: firewall.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23), protocol: "tcp")

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
