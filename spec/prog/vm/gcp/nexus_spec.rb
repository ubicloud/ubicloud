# frozen_string_literal: true

require "google/cloud/compute/v1"

RSpec.describe Prog::Vm::Gcp::Nexus do
  subject(:nx) {
    n = described_class.new(st)
    n.instance_variable_set(:@credential, location_credential)
    n
  }

  let(:st) {
    vm.strand
  }

  let(:project) { Project.create(name: "test-prj") }

  let(:location) {
    Location.create(name: "hetzner-fsn1", provider: "gcp", project_id: project.id,
      display_name: "gcp-us-central1", ui_name: "GCP US Central 1", visible: true)
  }

  let(:location_credential) {
    LocationCredential.create_with_id(location,
      project_id: "test-gcp-project",
      service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
      credentials_json: "{}")
  }

  let(:vm) {
    location_credential
    Prog::Vm::Nexus.assemble_with_sshable(project.id,
      location_id: location.id, unix_user: "test-user", boot_image: "ubuntu-noble",
      name: "testvm", size: "standard-2", arch: "x64").subject
  }

  let(:compute_client) { instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client) }
  let(:nfp_client) { instance_double(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client) }
  let(:zone_ops_client) { instance_double(Google::Cloud::Compute::V1::ZoneOperations::Rest::Client) }

  def ensure_nic_gcp_resource(nic, **overrides)
    return if NicGcpResource[nic.id]
    ps = nic.private_subnet
    NicGcpResource.create_with_id(
      nic.id,
      network_name: Prog::Vnet::Gcp::SubnetNexus.vpc_name(ps.location),
      subnet_name: "ubicloud-#{ps.ubid}",
      **overrides
    )
  end

  before do
    allow(location_credential).to receive_messages(
      compute_client:,
      network_firewall_policies_client: nfp_client,
      zone_operations_client: zone_ops_client
    )
  end

  describe ".assemble" do
    it "creates storage volumes for gcp location" do
      expect(vm.vm_storage_volumes.count).to eq(1)
      expect(vm.vm_storage_volumes.first.boot).to be true
    end

    it "creates strand with Vm::Gcp::Nexus prog" do
      expect(vm.strand.prog).to eq("Vm::Gcp::Nexus")
    end
  end

  describe "#before_destroy" do
    it "finalizes active billing records" do
      br = BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: vm.name,
        billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
        amount: vm.vcpus
      )

      expect { nx.before_destroy }
        .to change { br.reload.span.unbounded_end? }.from(true).to(false)
    end

    it "completes without billing records" do
      expect(vm.active_billing_records).to be_empty
      expect { nx.before_destroy }.not_to change { vm.reload.active_billing_records.count }
    end
  end

  describe "#start" do
    before do
      vm.nics.first.private_subnet.strand.update(label: "wait")
    end

    it "naps if private subnet is not in wait state" do
      vm.nics.first.strand.update(label: "wait")
      vm.nics.first.private_subnet.strand.update(label: "create_subnet")
      expect { nx.start }.to nap(5)
    end

    it "naps if vm nics are not in wait state" do
      vm.nics.first.strand.update(label: "start")
      expect { nx.start }.to nap(1)
    end

    it "creates a GCE instance without tags and hops to wait_create_op" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-12345")
      expect(compute_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        expect(args[:zone]).to eq("hetzner-fsn1-a")
        expect(args[:instance_resource]).to be_a(Google::Cloud::Compute::V1::Instance)
        expect(args[:instance_resource].name).to eq("testvm")
        expect(args[:instance_resource].machine_type).to include("e2-standard-2")

        # No classic tags should be set
        expect(args[:instance_resource].tags).to be_nil

        ni = args[:instance_resource].network_interfaces.first
        expect(ni.network).to eq("projects/test-gcp-project/global/networks/ubicloud-hetzner-fsn1")
        expect(ni.subnetwork).to include("subnetworks/ubicloud-")
        expect(ni.network_i_p).to eq(vm.nic.private_ipv4.network.to_s)
        expect(ni.stack_type).to eq("IPV4_IPV6")
        expect(ni.ipv6_access_configs.first.name).to eq("External IPv6")
        expect(ni.ipv6_access_configs.first.type).to eq("DIRECT_IPV6")
        op
      end

      expect { nx.start }.to hop("wait_create_op")
      expect(st.reload.stack.first["gcp_op_name"]).to eq("op-12345")
    end

    it "persists gcp_zone_suffix in VM strand frame" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      nic.strand.stack.first["gcp_zone_suffix"] = "c"
      nic.strand.modified!(:stack)
      nic.strand.save_changes
      ensure_nic_gcp_resource(nic)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-zone")
      expect(compute_client).to receive(:insert).and_return(op)

      expect { nx.start }.to hop("wait_create_op")
      expect(st.reload.stack.first["gcp_zone_suffix"]).to eq("c")
    end

    it "uses reserved static IP from NicGcpResource in AccessConfig" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.99")

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-static")
      expect(compute_client).to receive(:insert) do |args|
        ac = args[:instance_resource].network_interfaces.first.access_configs.first
        expect(ac.nat_i_p).to eq("35.192.0.99")
        op
      end

      expect { nx.start }.to hop("wait_create_op")
    end

    it "uses network config from NicGcpResource" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-net")
      expect(compute_client).to receive(:insert) do |args|
        ni = args[:instance_resource].network_interfaces.first
        ps = nic.private_subnet
        expect(ni.network).to include(Prog::Vnet::Gcp::SubnetNexus.vpc_name(ps.location))
        expect(ni.subnetwork).to include("ubicloud-#{ps.ubid}")
        op
      end

      expect { nx.start }.to hop("wait_create_op")
    end

    it "retries on ResourceExhaustedError with backoff" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      expect(compute_client).to receive(:insert).and_raise(Google::Cloud::ResourceExhaustedError.new("zone capacity"))
      expect(Clog).to receive(:emit).with("GCE zone capacity exhausted", anything)

      expect { nx.start }.to nap(30)
      expect(st.reload.stack.first["zone_retries"]).to eq(1)
    end

    it "retries on UnavailableError with backoff" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      expect(compute_client).to receive(:insert).and_raise(Google::Cloud::UnavailableError.new("service unavailable"))
      expect(Clog).to receive(:emit).with("GCE zone capacity exhausted", anything)

      expect { nx.start }.to nap(30)
      expect(st.reload.stack.first["zone_retries"]).to eq(1)
    end

    it "raises after 5 zone retries" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      st.stack.first["zone_retries"] = 4
      st.modified!(:stack)
      st.save_changes

      expect(compute_client).to receive(:insert).and_raise(Google::Cloud::ResourceExhaustedError.new("zone capacity"))

      expect { nx.start }.to raise_error(RuntimeError, /GCE instance creation failed after 5 zone retries/)
    end

    it "increments zone retry counter on successive retries" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      st.stack.first["zone_retries"] = 2
      st.modified!(:stack)
      st.save_changes

      expect(compute_client).to receive(:insert).and_raise(Google::Cloud::ResourceExhaustedError.new("zone capacity"))
      expect(Clog).to receive(:emit).with("GCE zone capacity exhausted", anything)

      expect { nx.start }.to nap(30)
      expect(st.reload.stack.first["zone_retries"]).to eq(3)
    end

    it "attaches persistent data disks for non-LSSD machine types" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)

      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 100, disk_index: 1)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-data-disk")
      expect(compute_client).to receive(:insert) do |args|
        disks = args[:instance_resource].disks
        expect(disks.length).to eq(2)
        expect(disks[0].boot).to be true
        expect(disks[1].boot).to be false
        expect(disks[1].initialize_params.disk_size_gb).to eq(100)
        op
      end

      expect { nx.start }.to hop("wait_create_op")
    end

    it "does not attach persistent data disks for LSSD machine types" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)

      vm.update(family: "c4a-standard", vcpus: 8)
      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 750, disk_index: 1)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-lssd")
      expect(compute_client).to receive(:insert) do |args|
        disks = args[:instance_resource].disks
        expect(disks.length).to eq(1)
        expect(disks[0].boot).to be true
        op
      end

      expect { nx.start }.to hop("wait_create_op")
    end

    it "hops to wait_create_op even when instance already exists" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      expect(compute_client).to receive(:insert).and_raise(Google::Cloud::AlreadyExistsError.new("exists"))
      expect { nx.start }.to hop("wait_create_op")
    end
  end

  describe "#wait_create_op" do
    it "hops to wait_instance_created when no operation is pending" do
      expect { nx.wait_create_op }.to hop("wait_instance_created")
    end

    it "hops to start when no operation is pending but zone_retries is set" do
      st.stack.first["zone_retries"] = 1
      st.modified!(:stack)
      st.save_changes
      expect { nx.wait_create_op }.to hop("start")
    end

    it "naps when operation is still running" do
      st.stack.first["gcp_op_name"] = "op-123"
      st.stack.first["gcp_op_scope"] = "zone"
      st.stack.first["gcp_op_scope_value"] = "hetzner-fsn1-a"
      st.modified!(:stack)
      st.save_changes

      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(zone_ops_client).to receive(:get).and_return(op)

      expect { nx.wait_create_op }.to nap(5)
    end

    it "hops to wait_instance_created when operation completes successfully" do
      st.stack.first["gcp_op_name"] = "op-123"
      st.stack.first["gcp_op_scope"] = "zone"
      st.stack.first["gcp_op_scope_value"] = "hetzner-fsn1-a"
      st.modified!(:stack)
      st.save_changes

      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(zone_ops_client).to receive(:get).and_return(op)

      expect { nx.wait_create_op }.to hop("wait_instance_created")
    end

    it "raises if the GCE operation fails" do
      st.stack.first["gcp_op_name"] = "op-123"
      st.stack.first["gcp_op_scope"] = "zone"
      st.stack.first["gcp_op_scope_value"] = "hetzner-fsn1-a"
      st.modified!(:stack)
      st.save_changes

      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "GENERIC_ERROR", message: "operation failed")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(zone_ops_client).to receive(:get).and_return(op)

      expect { nx.wait_create_op }.to raise_error(RuntimeError, /GCE instance creation failed.*operation failed/)
    end

    it "retries on ZONE_RESOURCE_POOL_EXHAUSTED operation error" do
      st.stack.first["gcp_op_name"] = "op-123"
      st.stack.first["gcp_op_scope"] = "zone"
      st.stack.first["gcp_op_scope_value"] = "hetzner-fsn1-a"
      st.modified!(:stack)
      st.save_changes

      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "ZONE_RESOURCE_POOL_EXHAUSTED", message: "exhausted")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(zone_ops_client).to receive(:get).and_return(op)
      expect(Clog).to receive(:emit).with("GCE zone capacity exhausted", anything)

      expect { nx.wait_create_op }.to nap(30)
      expect(st.reload.stack.first["zone_retries"]).to eq(1)
    end

    it "retries on QUOTA_EXCEEDED operation error" do
      st.stack.first["gcp_op_name"] = "op-123"
      st.stack.first["gcp_op_scope"] = "zone"
      st.stack.first["gcp_op_scope_value"] = "hetzner-fsn1-a"
      st.modified!(:stack)
      st.save_changes

      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "QUOTA_EXCEEDED", message: "quota exceeded")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(zone_ops_client).to receive(:get).and_return(op)
      expect(Clog).to receive(:emit).with("GCE zone capacity exhausted", anything)

      expect { nx.wait_create_op }.to nap(30)
      expect(st.reload.stack.first["zone_retries"]).to eq(1)
    end
  end

  describe "#wait_instance_created" do
    it "updates the vm and hops to wait_sshable when instance is RUNNING" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "RUNNING",
        network_interfaces: [
          Google::Cloud::Compute::V1::NetworkInterface.new(
            access_configs: [
              Google::Cloud::Compute::V1::AccessConfig.new(nat_i_p: "35.192.0.1")
            ],
            ipv6_access_configs: [
              Google::Cloud::Compute::V1::AccessConfig.new(external_ipv6: "2600:1900:4000:1::1")
            ]
          )
        ]
      )

      expect(compute_client).to receive(:get).with(
        project: "test-gcp-project",
        zone: "hetzner-fsn1-a",
        instance: "testvm"
      ).and_return(instance)

      now = Time.now.floor
      expect(Time).to receive(:now).at_least(:once).and_return(now)

      expect { nx.wait_instance_created }.to hop("wait_sshable")
        .and change { vm.reload.update_firewall_rules_set? }.from(false).to(true)
      expect(vm.cores).to eq(1)
      expect(vm.allocated_at).to eq(now)
      expect(vm.assigned_vm_address.ip.to_s).to eq("35.192.0.1/32")
      expect(vm.ephemeral_net6.to_s).to eq("2600:1900:4000:1::1/128")
    end

    it "updates the sshable host" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "RUNNING",
        network_interfaces: [
          Google::Cloud::Compute::V1::NetworkInterface.new(
            access_configs: [
              Google::Cloud::Compute::V1::AccessConfig.new(nat_i_p: "35.192.0.1")
            ],
            ipv6_access_configs: [
              Google::Cloud::Compute::V1::AccessConfig.new(external_ipv6: "2600:1900:4000:1::1")
            ]
          )
        ]
      )

      expect(compute_client).to receive(:get).and_return(instance)
      expect { nx.wait_instance_created }.to hop("wait_sshable")
        .and change { vm.sshable.reload.host }.to("35.192.0.1")
    end

    it "updates the vm when instance is RUNNING without network interfaces" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "RUNNING",
        network_interfaces: []
      )

      expect(compute_client).to receive(:get).and_return(instance)

      now = Time.now.floor
      expect(Time).to receive(:now).at_least(:once).and_return(now)

      expect { nx.wait_instance_created }.to hop("wait_sshable")
      vm.reload
      expect(vm.cores).to eq(1)
      expect(vm.assigned_vm_address).to be_nil
      expect(vm.ephemeral_net6).to be_nil
    end

    it "updates the vm when instance is RUNNING with empty access_configs" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "RUNNING",
        network_interfaces: [
          Google::Cloud::Compute::V1::NetworkInterface.new
        ]
      )

      expect(compute_client).to receive(:get).and_return(instance)

      now = Time.now.floor
      expect(Time).to receive(:now).at_least(:once).and_return(now)

      expect { nx.wait_instance_created }.to hop("wait_sshable")
      vm.reload
      expect(vm.cores).to eq(1)
      expect(vm.assigned_vm_address).to be_nil
      expect(vm.ephemeral_net6).to be_nil
    end

    it "naps if the instance is in STAGING state" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "STAGING",
        network_interfaces: []
      )

      expect(compute_client).to receive(:get).and_return(instance)
      expect { nx.wait_instance_created }.to nap(5)
    end

    it "naps if the instance is in PROVISIONING state" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "PROVISIONING",
        network_interfaces: []
      )

      expect(compute_client).to receive(:get).and_return(instance)
      expect { nx.wait_instance_created }.to nap(5)
    end

    it "raises if the instance enters TERMINATED state" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "TERMINATED",
        network_interfaces: []
      )

      expect(compute_client).to receive(:get).and_return(instance)
      expect { nx.wait_instance_created }.to raise_error(RuntimeError, /GCE instance entered terminal state: TERMINATED/)
    end

    it "raises if the instance enters SUSPENDED state" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "SUSPENDED",
        network_interfaces: []
      )

      expect(compute_client).to receive(:get).and_return(instance)
      expect { nx.wait_instance_created }.to raise_error(RuntimeError, /GCE instance entered terminal state: SUSPENDED/)
    end
  end

  describe "#wait_sshable" do
    it "pushes update_firewall_rules when semaphore is set" do
      vm.incr_update_firewall_rules
      expect(nx).to receive(:push).with(Prog::Vnet::Gcp::UpdateFirewallRules, {}, :update_firewall_rules).and_call_original
      expect { nx.wait_sshable }.to hop(:update_firewall_rules, "Vnet::Gcp::UpdateFirewallRules")
    end

    it "decrements semaphore when firewall rules are added" do
      vm.incr_update_firewall_rules
      st.update(retval: Sequel.pg_jsonb({"msg" => "firewall rule is added"}))
      expect { nx.wait_sshable }.to hop("create_billing_record")
        .and change { vm.reload.update_firewall_rules_set? }.from(true).to(false)
    end

    it "naps if not sshable" do
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "10.0.0.1/32")
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1).and_raise Errno::ECONNREFUSED
      expect { nx.wait_sshable }.to nap(1)
    end

    it "hops to create_billing_record if sshable" do
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "10.0.0.1/32")
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1)
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end

    it "hops to create_billing_record if ipv4 is not available" do
      expect(vm.ip4).to be_nil
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end
  end

  describe "#create_billing_record" do
    let(:now) { Time.now }

    before do
      expect(Time).to receive(:now).and_return(now).at_least(:once)
      vm.update(allocated_at: now - 100)
      expect(Clog).to receive(:emit).with("vm provisioned", instance_of(Array)).and_call_original
    end

    it "does not create billing records when the project is not billable" do
      vm.project.update(billable: false)
      expect { nx.create_billing_record }.to hop("wait")
      expect(BillingRecord.all).to be_empty
    end

    it "creates billing records for vm" do
      expect { nx.create_billing_record }.to hop("wait")
        .and change(BillingRecord, :count).from(0).to(1)
        .and change { vm.reload.display_state }.from("creating").to("running")
      expect(vm.active_billing_records.first.billing_rate["resource_type"]).to eq("VmVCpu")
      expect(vm.provisioned_at).to be_within(1).of(now)
    end
  end

  describe "#wait" do
    it "naps when nothing to do" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to update_firewall_rules when needed" do
      nx.incr_update_firewall_rules
      expect { nx.wait }.to hop("update_firewall_rules")
    end
  end

  describe "#update_firewall_rules" do
    it "pushes firewall rules prog" do
      nx.incr_update_firewall_rules
      expect(nx).to receive(:push).with(Prog::Vnet::Gcp::UpdateFirewallRules, {}, :update_firewall_rules)
      nx.update_firewall_rules
      expect(Semaphore.where(strand_id: st.id, name: "update_firewall_rules").all).to be_empty
    end

    it "hops to wait if firewall rules are applied" do
      expect(nx).to receive(:retval).and_return({"msg" => "firewall rule is added"})
      expect { nx.update_firewall_rules }.to hop("wait")
    end
  end

  describe "#prevent_destroy" do
    it "registers a deadline and naps while preventing" do
      now = Time.now
      expect(Time).to receive(:now).at_least(:once).and_return(now)
      expect { nx.prevent_destroy }.to nap(30)
      expect(nx.strand.stack.first["deadline_target"]).to eq("destroy")
      expect(nx.strand.stack.first["deadline_at"]).to eq(now + 24 * 60 * 60)
    end
  end

  describe "#destroy" do
    it "prevents destroy if the semaphore set" do
      nx.incr_prevent_destroy
      expect(Clog).to receive(:emit).with("Destroy prevented by the semaphore").and_call_original
      expect { nx.destroy }.to hop("prevent_destroy")
    end

    it "deletes the GCE instance and hops to wait_destroy_op" do
      expect(nx).to receive(:cleanup_vm_policy_rules)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-del-123")
      expect(compute_client).to receive(:delete).with(
        project: "test-gcp-project",
        zone: "hetzner-fsn1-a",
        instance: "testvm"
      ).and_return(op)

      expect { nx.destroy }.to hop("wait_destroy_op")
      expect(st.reload.stack.first["gcp_op_name"]).to eq("op-del-123")
    end

    it "handles already-deleted instances by hopping to finalize_destroy" do
      expect(nx).to receive(:cleanup_vm_policy_rules)
      expect(compute_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect { nx.destroy }.to hop("finalize_destroy")
    end

    it "uses zone from VM strand frame when NIC is already destroyed" do
      st.stack.first["gcp_zone_suffix"] = "c"
      st.modified!(:stack)
      st.save_changes

      nx.instance_variable_set(:@nic, nil)
      allow(vm).to receive(:nic).and_return(nil)

      expect(nx).to receive(:cleanup_vm_policy_rules)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-del-zone")
      expect(compute_client).to receive(:delete).with(
        project: "test-gcp-project",
        zone: "hetzner-fsn1-c",
        instance: "testvm"
      ).and_return(op)

      expect { nx.destroy }.to hop("wait_destroy_op")
    end

    it "handles firewall cleanup errors gracefully" do
      expect(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::Error.new("permission denied"))
      allow(Clog).to receive(:emit).and_call_original
      expect(Clog).to receive(:emit).with("Failed to clean up GCE firewall resources", anything)

      expect(compute_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect { nx.destroy }.to hop("finalize_destroy")
    end
  end

  describe "#cleanup_vm_policy_rules" do
    before do
      ensure_nic_gcp_resource(vm.nics.first)
    end

    it "removes policy rules matching the VM's private IP" do
      vm_ip = vm.nics.first.private_ipv4.network.to_s
      vm_dest = "#{vm_ip}/32"

      matching_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 12345,
        direction: "INGRESS",
        action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: [vm_dest]
        )
      )
      other_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 54321,
        direction: "INGRESS",
        action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: ["10.99.99.99/32"]
        )
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [matching_rule, other_rule])
      expect(nfp_client).to receive(:get).with(
        project: "test-gcp-project",
        firewall_policy: "ubicloud-hetzner-fsn1"
      ).and_return(policy)
      expect(nfp_client).to receive(:remove_rule).with(hash_including(priority: 12345))
      expect(nfp_client).not_to receive(:remove_rule).with(hash_including(priority: 54321))

      nx.send(:cleanup_vm_policy_rules)
    end

    it "returns when policy is not found" do
      expect(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:cleanup_vm_policy_rules)
    end

    it "returns when vm has no private IP" do
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      expect(nfp_client).to receive(:get).and_return(policy)

      nic = vm.nics.first
      allow(nic).to receive(:private_ipv4).and_return(nil)
      nx.instance_variable_set(:@nic, nic)

      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:cleanup_vm_policy_rules)
    end

    it "handles cleanup errors gracefully" do
      expect(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::Error.new("permission denied"))
      expect(Clog).to receive(:emit).with("Failed to clean up GCE firewall resources", anything)

      nx.send(:cleanup_vm_policy_rules)
    end

    it "returns when nic is nil" do
      # Override nic method to return nil (||= can't cache nil)
      allow(nx).to receive(:nic).and_return(nil)

      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [])
      expect(nfp_client).to receive(:get).and_return(policy)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:cleanup_vm_policy_rules)
    end

    it "skips non-INGRESS and non-allow rules" do
      vm_ip = vm.nics.first.private_ipv4.network.to_s
      vm_dest = "#{vm_ip}/32"

      egress_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 11111,
        direction: "EGRESS",
        action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: [vm_dest]
        )
      )
      deny_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 22222,
        direction: "INGRESS",
        action: "deny",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: [vm_dest]
        )
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [egress_rule, deny_rule])
      expect(nfp_client).to receive(:get).and_return(policy)

      expect(nfp_client).not_to receive(:remove_rule)
      nx.send(:cleanup_vm_policy_rules)
    end

    it "skips rules with nil match or nil dest_ip_ranges" do
      nil_match_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 33333,
        direction: "INGRESS",
        action: "allow"
        # match is nil
      )
      nil_dest_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        priority: 44444,
        direction: "INGRESS",
        action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: ["0.0.0.0/0"]
          # dest_ip_ranges is nil
        )
      )
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(rules: [nil_match_rule, nil_dest_rule])
      expect(nfp_client).to receive(:get).and_return(policy)

      expect(nfp_client).not_to receive(:remove_rule)
      nx.send(:cleanup_vm_policy_rules)
    end
  end

  describe "#wait_destroy_op" do
    before do
      st.stack.first["gcp_op_name"] = "op-del-123"
      st.stack.first["gcp_op_scope"] = "zone"
      st.stack.first["gcp_op_scope_value"] = "hetzner-fsn1-a"
      st.modified!(:stack)
      st.save_changes
    end

    it "naps when operation is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(zone_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_destroy_op }.to nap(5)
    end

    it "hops to finalize_destroy when operation completes" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(zone_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_destroy_op }.to hop("finalize_destroy")
    end
  end

  describe "#finalize_destroy" do
    it "destroys the vm and pops" do
      expect { nx.finalize_destroy }.to exit({"msg" => "vm destroyed"})
    end

    it "detaches NIC and increments destroy when NIC exists" do
      nic = vm.nics.first
      expect(nic.vm_id).to eq(vm.id)

      expect { nx.finalize_destroy }.to exit({"msg" => "vm destroyed"})
      expect(nic.reload.vm_id).to be_nil
      expect(Semaphore.where(strand_id: nic.strand.id, name: "destroy").count).to eq(1)
    end

    it "skips NIC detach when NIC is nil" do
      vm.nics.each { |n|
        n.strand.destroy
        n.destroy
      }

      expect { nx.finalize_destroy }.to exit({"msg" => "vm destroyed"})
    end
  end

  describe "helper methods" do
    it "returns e2-standard-2 for standard family with 2 vcpus" do
      expect(nx.send(:gce_machine_type)).to eq("e2-standard-2")
    end

    it "falls back to c3d-standard-lssd for standard family with 8+ vcpus" do
      vm.update(vcpus: 8)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("c3d-standard-8-lssd")
    end

    it "returns e2-small for burstable family with 1 vcpu" do
      vm.update(family: "burstable", vcpus: 1)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("e2-small")
    end

    it "returns e2-medium for burstable family with 2 vcpus" do
      vm.update(family: "burstable", vcpus: 2)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("e2-medium")
    end

    it "maps c4a-standard family to c4a-standard-N-lssd" do
      vm.update(family: "c4a-standard", vcpus: 8)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("c4a-standard-8-lssd")
    end

    it "maps c4a-highmem family to c4a-highmem-N-lssd" do
      vm.update(family: "c4a-highmem", vcpus: 16)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("c4a-highmem-16-lssd")
    end

    it "maps c3-standard family to c3-standard-N-lssd" do
      vm.update(family: "c3-standard", vcpus: 22)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("c3-standard-22-lssd")
    end

    it "maps c3d-standard family to c3d-standard-N-lssd" do
      vm.update(family: "c3d-standard", vcpus: 30)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("c3d-standard-30-lssd")
    end

    it "maps c3d-highmem family to c3d-highmem-N-lssd" do
      vm.update(family: "c3d-highmem", vcpus: 60)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("c3d-highmem-60-lssd")
    end

    it "snaps vcpu count up to nearest valid size for the family" do
      vm.update(family: "c4a-standard", vcpus: 5)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("c4a-standard-8-lssd")
    end

    it "snaps to largest size when vcpus exceed maximum for the family" do
      vm.update(family: "c4a-standard", vcpus: 100)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("c4a-standard-72-lssd")
    end

    it "returns true for uses_local_ssd? on LSSD types" do
      vm.update(family: "c3d-standard", vcpus: 8)
      vm.reload
      expect(nx.send(:uses_local_ssd?)).to be true
    end

    it "returns false for uses_local_ssd? on e2 types" do
      expect(nx.send(:uses_local_ssd?)).to be false
    end

    it "falls back to c3d-standard-360-lssd for standard family with very high vcpus" do
      vm.update(vcpus: 500)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("c3d-standard-360-lssd")
    end

    it "maps ubuntu-noble to GCE ubuntu-2404-lts-amd64 family for x64" do
      expect(nx.send(:gce_source_image)).to eq("projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64")
    end

    it "maps ubuntu-noble to GCE ubuntu-2404-lts-arm64 family for arm64" do
      vm.update(arch: "arm64")
      expect(nx.send(:gce_source_image)).to eq("projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-arm64")
    end

    it "maps ubuntu-jammy to GCE ubuntu-2204-lts family for x64" do
      vm.update(boot_image: "ubuntu-jammy")
      expect(nx.send(:gce_source_image)).to eq("projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts")
    end

    it "maps ubuntu-jammy to GCE ubuntu-2204-lts-arm64 family for arm64" do
      vm.update(boot_image: "ubuntu-jammy", arch: "arm64")
      expect(nx.send(:gce_source_image)).to eq("projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts-arm64")
    end

    it "returns custom GCE image when boot_image starts with projects/" do
      vm.update(boot_image: "projects/test-gcp-project/global/images/postgres-ubuntu-2204-x64-20260218")
      expect(nx.send(:gce_source_image)).to eq("projects/test-gcp-project/global/images/postgres-ubuntu-2204-x64-20260218")
    end

    it "raises error for unknown boot image" do
      vm.update(boot_image: "unknown-image")
      expect { nx.send(:gce_source_image) }.to raise_error(RuntimeError, /Unknown boot image 'unknown-image'/)
    end

    it "raises error for nil boot image" do
      allow(nx.vm).to receive(:boot_image).and_return(nil)
      expect { nx.send(:gce_source_image) }.to raise_error(RuntimeError, /Unknown boot image/)
    end

    it "returns correct GCP zone defaulting to suffix a" do
      expect(nx.send(:gcp_zone)).to eq("hetzner-fsn1-a")
    end

    it "reads GCP zone suffix from VM strand frame first" do
      st.stack.first["gcp_zone_suffix"] = "c"
      st.modified!(:stack)
      st.save_changes
      vm.nic.strand.stack.first["gcp_zone_suffix"] = "b"
      vm.nic.strand.modified!(:stack)
      vm.nic.strand.save_changes
      expect(nx.send(:gcp_zone)).to eq("hetzner-fsn1-c")
    end

    it "falls back to NIC strand frame when VM strand has no zone suffix" do
      vm.nic.strand.stack.first["gcp_zone_suffix"] = "b"
      vm.nic.strand.modified!(:stack)
      vm.nic.strand.save_changes
      expect(nx.send(:gcp_zone)).to eq("hetzner-fsn1-b")
    end

    it "defaults to zone suffix 'a' when NIC is nil" do
      vm.nics.each { |n|
        n.strand.destroy
        n.destroy
      }
      nx.instance_variable_set(:@nic, nil)
      nx.instance_variable_set(:@gcp_zone, nil)
      expect(nx.send(:gcp_zone)).to eq("hetzner-fsn1-a")
    end

    it "returns the GCP region from location name" do
      expect(nx.send(:gcp_region)).to eq("hetzner-fsn1")
    end
  end
end
