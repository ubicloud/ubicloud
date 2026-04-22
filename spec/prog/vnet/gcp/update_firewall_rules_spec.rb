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

  let(:compute_client) { instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client) }
  let(:crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }
  let(:regional_crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }

  # Namespaced-name bindings - VM side never touches canonical "tagValues/{id}";
  # it constructs these deterministically from project_id + firewall.ubid.
  let(:fw_tag_value_name) { "test-gcp-project/ubicloud-fw-#{firewall.ubid}/active" }
  let(:subnet_tag_value_name) { "test-gcp-project/ubicloud-subnet-#{ps.ubid}/member" }

  let(:instance_obj) { Google::Cloud::Compute::V1::Instance.new(name: vm.name, id: 9876543210) }
  let(:project_obj) { Google::Apis::CloudresourcemanagerV3::Project.new(name: "projects/73189733048") }

  before do
    allow(nx.send(:credential)).to receive_messages(
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
      # No CRM list_tag_keys / list_tag_values stubs: the VM side now
      # constructs namespaced names directly from ubids.
      empty_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse, tag_bindings: [])
      binding_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      allow(regional_crm_client).to receive_messages(list_tag_bindings: empty_bindings, create_tag_binding: binding_op)
    end

    it "binds firewall and subnet tags then pops" do
      expect(regional_crm_client).to receive(:create_tag_binding).twice

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "does not create any tag keys or values (VpcNexus owns that)" do
      expect(crm_client).not_to receive(:create_tag_key)
      expect(crm_client).not_to receive(:create_tag_value)
      expect(regional_crm_client).to receive(:create_tag_binding).twice

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "omits firewalls with no rules (infrastructure exists but binding is pointless)" do
      fw_rule.destroy

      # Only subnet tag should be bound (firewall has no rules → not bound).
      expect(regional_crm_client).to receive(:create_tag_binding).once do |binding|
        expect(binding.tag_value_namespaced_name).to eq(subnet_tag_value_name)
      end

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "binds tags for multiple firewalls attached to the same VM" do
      firewall2 = Firewall.create(name: "fw2", location_id: location.id, project_id: project.id)
      firewall2.associate_with_private_subnet(ps, apply_firewalls: false)
      FirewallRule.create(firewall_id: firewall2.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(443...444))
      firewall2_tag = "test-gcp-project/ubicloud-fw-#{firewall2.ubid}/active"

      bound = []
      expect(regional_crm_client).to receive(:create_tag_binding).exactly(3).times do |binding|
        bound << binding.tag_value_namespaced_name
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      end

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
      expect(bound).to contain_exactly(fw_tag_value_name, firewall2_tag, subnet_tag_value_name)
    end

    it "unbinds stale tags from firewalls no longer attached" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value_namespaced_name: "tagValues/old-fw-tv")
      active_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/active-1", tag_value_namespaced_name: fw_tag_value_name)

      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding, active_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      unbind_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "unbind-op", error: nil)
      expect(regional_crm_client).to receive(:delete_tag_binding).with("tagBindings/stale-1").and_return(unbind_op)
      expect(regional_crm_client).not_to receive(:delete_tag_binding).with("tagBindings/active-1")
      expect(regional_crm_client).to receive(:create_tag_binding).once

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "creates new tag bindings before deleting stale ones" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value_namespaced_name: "tagValues/old-fw-tv")
      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      unbind_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "unbind-op", error: nil)
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
      expect(call_order.rindex(:create)).to be < call_order.index(:delete)
    end

    it "hops to wait_tag_binding_deletes when NIC tag limit hit and stale bindings exist" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value_namespaced_name: "tagValues/old-fw-tv")
      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      unbind_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: false, name: "operations/unbind-1", error: nil)

      expect(regional_crm_client).to receive(:create_tag_binding).twice do |binding|
        if binding.tag_value_namespaced_name == fw_tag_value_name
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
        name: "tagBindings/stale-denied", tag_value_namespaced_name: "tagValues/old-tv")
      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      expect(regional_crm_client).to receive(:create_tag_binding).twice do |binding|
        if binding.tag_value_namespaced_name == fw_tag_value_name
          raise Google::Apis::ClientError.new("tag limit exceeded", status_code: 400)
        end
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      end
      expect(regional_crm_client).to receive(:delete_tag_binding).with("tagBindings/stale-denied")
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.update_firewall_rules }.to raise_error(Google::Apis::ClientError)
      stashed = st.reload.stack.first
      expect(stashed["pending_tag_binding_deletes"]).to be_nil
      expect(stashed["failed_creates_to_retry"]).to be_nil
    end

    it "filters 404 deletes out of pending_tag_binding_deletes on the retry path" do
      stale_binding_404 = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/gone-1", tag_value_namespaced_name: "tagValues/gone-tv")
      stale_binding_ok = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-2", tag_value_namespaced_name: "tagValues/old-tv")
      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding_404, stale_binding_ok])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)

      unbind_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: false, name: "operations/unbind-ok", error: nil)
      expect(regional_crm_client).to receive(:create_tag_binding).twice do |binding|
        if binding.tag_value_namespaced_name == fw_tag_value_name
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

      expect { nx.update_firewall_rules }.to raise_error(Google::Apis::ClientError)
    end

    it "naps when create 400s, no stale bindings, and re-read confirms binding absent" do
      active_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/active-1", tag_value_namespaced_name: fw_tag_value_name)
      initial_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [active_binding])
      reread_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [active_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(initial_list, reread_list)
      expect(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("bad request", status_code: 400))
      expect(regional_crm_client).not_to receive(:delete_tag_binding)
      expect(Clog).to receive(:emit)
        .with("Tag binding 400 with binding not present, napping for retry", hash_including(:tag_value, :parent))
        .and_call_original

      expect { nx.update_firewall_rules }.to nap(5)
    end

    it "naps when create 400s and the re-read returns nil tag_bindings" do
      active_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/active-1", tag_value_namespaced_name: fw_tag_value_name)
      initial_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [active_binding])
      reread_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse, tag_bindings: nil)
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(initial_list, reread_list)
      expect(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("bad request", status_code: 400))
      expect(Clog).to receive(:emit)
        .with("Tag binding 400 with binding not present, napping for retry", hash_including(:tag_value, :parent))
        .and_call_original

      expect { nx.update_firewall_rules }.to nap(5)
    end

    it "proceeds when create 400s but re-read shows the binding actually landed" do
      active_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/active-1", tag_value_namespaced_name: fw_tag_value_name)
      landed_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/landed-1", tag_value_namespaced_name: subnet_tag_value_name)
      initial_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [active_binding])
      reread_list = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [active_binding, landed_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(initial_list, reread_list)
      expect(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("bad request", status_code: 400))
      expect(Clog).not_to receive(:emit).with("Tag binding 400 with binding not present, napping for retry", anything)

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "truncates desired tags and logs when exceeding GCP 10-tag NIC limit" do
      (2..11).map { |i|
        fw = Firewall.create(name: "fw#{i}", location_id: location.id, project_id: project.id)
        FirewallRule.create(firewall_id: fw.id, cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22...23))
        DB[:firewalls_private_subnets].insert(private_subnet_id: ps.id, firewall_id: fw.id)
        fw
      }

      bound_tags = []
      expect(regional_crm_client).to receive(:create_tag_binding).exactly(10).times do |binding|
        bound_tags << binding.tag_value_namespaced_name
        instance_double(Google::Apis::CloudresourcemanagerV3::Operation, done?: true, name: "bind-op", error: nil)
      end

      expect(Clog).to receive(:emit).with("GCP NIC tag limit exceeded, truncating to 10", anything).and_call_original

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
      # Subnet tag is always preserved in the truncation; 9 firewalls + 1 subnet = 10.
      expect(bound_tags).to include(subnet_tag_value_name)
      expect(bound_tags.size).to eq(10)
    end

    it "skips already-bound tags" do
      existing_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/existing-1", tag_value_namespaced_name: fw_tag_value_name)
      subnet_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/existing-2", tag_value_namespaced_name: subnet_tag_value_name)
      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [existing_binding, subnet_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)
      expect(regional_crm_client).not_to receive(:create_tag_binding)
      expect(regional_crm_client).not_to receive(:delete_tag_binding)

      expect { nx.update_firewall_rules }.to hop("wait_sshable", "Vm::Gcp::Nexus")
    end

    it "handles unbind 404 gracefully" do
      stale_binding = instance_double(Google::Apis::CloudresourcemanagerV3::TagBinding,
        name: "tagBindings/stale-1", tag_value_namespaced_name: "tagValues/old")
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
        name: "tagBindings/stale-1", tag_value_namespaced_name: "tagValues/old")
      existing_bindings = instance_double(Google::Apis::CloudresourcemanagerV3::ListTagBindingsResponse,
        tag_bindings: [stale_binding])
      expect(regional_crm_client).to receive(:list_tag_bindings).and_return(existing_bindings)
      expect(regional_crm_client).to receive(:delete_tag_binding)
        .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

      expect { nx.update_firewall_rules }.to raise_error(Google::Apis::ClientError)
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
        retried << binding.tag_value_namespaced_name
        bind_op
      end

      expect { nx.wait_tag_binding_deletes }.to hop("update_firewall_rules")
      expect(retried).to eq(["tagValues/retry-1", "tagValues/retry-2"])
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
    end

    it "raises CrmOperationError when a delete operation has an error" do
      refresh_frame(nx, new_values: {
        "pending_tag_binding_deletes" => ["operations/op-err"],
        "failed_creates_to_retry" => ["tagValues/retry-1"],
      })
      error_status = instance_double(Google::Apis::CloudresourcemanagerV3::Status, code: 7, message: "PERMISSION_DENIED")
      err_op = instance_double(Google::Apis::CloudresourcemanagerV3::Operation,
        done?: true, name: "operations/op-err", error: error_status)
      expect(regional_crm_client).to receive(:get_operation).with("operations/op-err").and_return(err_op)

      expect { nx.wait_tag_binding_deletes }
        .to raise_error(described_class::CrmOperationError) { |e| expect(e.code).to eq(7) }
    end

    it "tolerates missing frame keys (defensive nil handling)" do
      expect(regional_crm_client).not_to receive(:get_operation)
      expect(regional_crm_client).not_to receive(:create_tag_binding)

      expect { nx.wait_tag_binding_deletes }.to hop("update_firewall_rules")
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
      expect { nx.send(:create_tag_binding, "//compute.googleapis.com/...", "tagValues/tv-1") }
        .to raise_error(Google::Apis::ClientError)
    end

    it "re-raises 400 errors" do
      expect(regional_crm_client).to receive(:create_tag_binding)
        .and_raise(Google::Apis::ClientError.new("bad request", status_code: 400))
      expect { nx.send(:create_tag_binding, "//compute.googleapis.com/...", "tagValues/tv-1") }
        .to raise_error(Google::Apis::ClientError)
    end
  end

  describe "vm_instance_resource_name" do
    it "returns the resource name with project number and instance ID" do
      result = nx.send(:vm_instance_resource_name)
      expect(result).to eq("//compute.googleapis.com/projects/73189733048/zones/us-central1-a/instances/9876543210")
    end
  end

  describe "namespaced name helpers" do
    it "constructs firewall tag namespaced name from project_id and firewall ubid" do
      expect(nx.send(:firewall_tag_namespaced_name, firewall)).to eq("test-gcp-project/ubicloud-fw-#{firewall.ubid}/active")
    end

    it "constructs subnet tag namespaced name from project_id and subnet ubid" do
      expect(nx.send(:subnet_tag_namespaced_name)).to eq("test-gcp-project/ubicloud-subnet-#{ps.ubid}/member")
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

    it "returns gcp_project_number from CRM" do
      expect(nx.send(:gcp_project_number)).to eq("73189733048")
    end
  end
end
