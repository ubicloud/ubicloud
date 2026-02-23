# frozen_string_literal: true

require "google/cloud/compute/v1"

RSpec.describe Prog::Vm::Gcp::Nexus do
  subject(:nx) {
    described_class.new(st)
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
  let(:fw_client) { instance_double(Google::Cloud::Compute::V1::Firewalls::Rest::Client) }

  before do
    allow_any_instance_of(LocationCredential).to receive(:compute_client).and_return(compute_client)
    allow_any_instance_of(LocationCredential).to receive(:firewalls_client).and_return(fw_client)
    allow(fw_client).to receive(:list).and_return([])
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
    it "naps if vm nics are not in wait state" do
      vm.nics.first.strand.update(label: "start")
      expect { nx.start }.to nap(1)
    end

    it "creates a dual-stack GCE instance and hops to wait_instance_created" do
      vm.nics.first.strand.update(label: "wait")
      op = instance_double(Gapic::GenericLRO::Operation, error?: false)
      expect(op).to receive(:wait_until_done!)
      expect(compute_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        expect(args[:zone]).to eq("hetzner-fsn1-a")
        expect(args[:instance_resource]).to be_a(Google::Cloud::Compute::V1::Instance)
        expect(args[:instance_resource].name).to eq("testvm")
        expect(args[:instance_resource].machine_type).to include("e2-standard-2")

        ni = args[:instance_resource].network_interfaces.first
        expect(ni.network).to eq("projects/test-gcp-project/global/networks/ubicloud-proj-#{project.ubid}")
        expect(ni.subnetwork).to include("subnetworks/ubicloud-")
        expect(ni.network_i_p).to eq(vm.nic.private_ipv4.network.to_s)
        expect(ni.stack_type).to eq("IPV4_IPV6")
        expect(ni.ipv6_access_configs.first.name).to eq("External IPv6")
        expect(ni.ipv6_access_configs.first.type).to eq("DIRECT_IPV6")
        op
      end

      expect { nx.start }.to hop("wait_instance_created")
    end

    it "persists gcp_zone_suffix in VM strand frame" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      nic.strand.stack.first["gcp_zone_suffix"] = "c"
      nic.strand.modified!(:stack)
      nic.strand.save_changes

      op = instance_double(Gapic::GenericLRO::Operation, error?: false)
      expect(op).to receive(:wait_until_done!)
      expect(compute_client).to receive(:insert).and_return(op)

      expect { nx.start }.to hop("wait_instance_created")
      expect(st.reload.stack.first["gcp_zone_suffix"]).to eq("c")
    end

    it "uses reserved static IP in AccessConfig when NicGcpResource exists" do
      nic = vm.nics.first
      nic.strand.update(label: "wait")
      NicGcpResource.create_with_id(nic.id, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.99")

      op = instance_double(Gapic::GenericLRO::Operation, error?: false)
      expect(op).to receive(:wait_until_done!)
      expect(compute_client).to receive(:insert) do |args|
        ac = args[:instance_resource].network_interfaces.first.access_configs.first
        expect(ac.nat_i_p).to eq("35.192.0.99")
        op
      end

      expect { nx.start }.to hop("wait_instance_created")
    end

    it "raises if the GCE operation fails" do
      vm.nics.first.strand.update(label: "wait")
      error_result = Struct.new(:error).new("operation failed")
      lro_err = Struct.new(:code, :message).new(400, "operation failed")
      op = instance_double(Gapic::GenericLRO::Operation, error?: true, error: lro_err, results: error_result)
      expect(op).to receive(:wait_until_done!)
      expect(compute_client).to receive(:insert).and_return(op)

      expect { nx.start }.to raise_error(RuntimeError, /GCE instance creation failed.*operation failed/)
    end

    it "retries on ResourceExhaustedError with backoff" do
      vm.nics.first.strand.update(label: "wait")
      expect(compute_client).to receive(:insert).and_raise(Google::Cloud::ResourceExhaustedError.new("zone capacity"))
      expect(Clog).to receive(:emit).with("GCE zone capacity exhausted")

      expect { nx.start }.to nap(30)
      expect(st.reload.stack.first["zone_retries"]).to eq(1)
    end

    it "retries on UnavailableError with backoff" do
      vm.nics.first.strand.update(label: "wait")
      expect(compute_client).to receive(:insert).and_raise(Google::Cloud::UnavailableError.new("service unavailable"))
      expect(Clog).to receive(:emit).with("GCE zone capacity exhausted")

      expect { nx.start }.to nap(30)
      expect(st.reload.stack.first["zone_retries"]).to eq(1)
    end

    it "retries on ZONE_RESOURCE_POOL_EXHAUSTED operation error" do
      vm.nics.first.strand.update(label: "wait")
      error_entry = Struct.new(:code).new("ZONE_RESOURCE_POOL_EXHAUSTED")
      error_info = Struct.new(:errors).new([error_entry])
      error_result = Struct.new(:error).new(error_info)
      op = instance_double(Gapic::GenericLRO::Operation, error?: true, results: error_result)
      expect(op).to receive(:wait_until_done!)
      expect(compute_client).to receive(:insert).and_return(op)
      expect(Clog).to receive(:emit).with("GCE zone capacity exhausted")

      expect { nx.start }.to nap(30)
      expect(st.reload.stack.first["zone_retries"]).to eq(1)
    end

    it "retries on QUOTA_EXCEEDED operation error" do
      vm.nics.first.strand.update(label: "wait")
      error_entry = Struct.new(:code).new("QUOTA_EXCEEDED")
      error_info = Struct.new(:errors).new([error_entry])
      error_result = Struct.new(:error).new(error_info)
      op = instance_double(Gapic::GenericLRO::Operation, error?: true, results: error_result)
      expect(op).to receive(:wait_until_done!)
      expect(compute_client).to receive(:insert).and_return(op)
      expect(Clog).to receive(:emit).with("GCE zone capacity exhausted")

      expect { nx.start }.to nap(30)
      expect(st.reload.stack.first["zone_retries"]).to eq(1)
    end

    it "retries on QUOTA_EXCEEDED when results does not respond to error" do
      vm.nics.first.strand.update(label: "wait")
      error_entry = Struct.new(:code).new("QUOTA_EXCEEDED")
      generic_error = Struct.new(:errors).new([error_entry])
      op = instance_double(Gapic::GenericLRO::Operation, error?: true, results: generic_error)
      expect(op).to receive(:wait_until_done!)
      expect(compute_client).to receive(:insert).and_return(op)
      expect(Clog).to receive(:emit).with("GCE zone capacity exhausted")

      expect { nx.start }.to nap(30)
      expect(st.reload.stack.first["zone_retries"]).to eq(1)
    end

    it "raises after 5 zone retries" do
      vm.nics.first.strand.update(label: "wait")
      st.stack.first["zone_retries"] = 4
      st.modified!(:stack)
      st.save_changes

      expect(compute_client).to receive(:insert).and_raise(Google::Cloud::ResourceExhaustedError.new("zone capacity"))

      expect { nx.start }.to raise_error(RuntimeError, /GCE instance creation failed after 5 zone retries/)
    end

    it "increments zone retry counter on successive retries" do
      vm.nics.first.strand.update(label: "wait")
      st.stack.first["zone_retries"] = 2
      st.modified!(:stack)
      st.save_changes

      expect(compute_client).to receive(:insert).and_raise(Google::Cloud::ResourceExhaustedError.new("zone capacity"))
      expect(Clog).to receive(:emit).with("GCE zone capacity exhausted")

      expect { nx.start }.to nap(30)
      expect(st.reload.stack.first["zone_retries"]).to eq(3)
    end
  end

  describe "#wait_instance_created" do
    it "updates the vm with IPv4 and IPv6 when instance is RUNNING" do
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
      vm.reload
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
    it "increments update_firewall_rules semaphore and hops to create_billing_record on first run" do
      expect { nx.wait_sshable }.to hop("create_billing_record")
        .and change { vm.reload.update_firewall_rules_set? }.from(false).to(true)
    end

    it "pushes update_firewall_rules when semaphore is already set" do
      vm.incr_update_firewall_rules
      expect(nx).to receive(:push).with(Prog::Vnet::Gcp::UpdateFirewallRules, {}, :update_firewall_rules).and_call_original
      expect { nx.wait_sshable }.to hop(:update_firewall_rules, "Vnet::Gcp::UpdateFirewallRules")
    end

    it "naps if not sshable" do
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "10.0.0.1/32")
      st.update(retval: Sequel.pg_jsonb({"msg" => "firewall rule is added"}))
      vm.incr_update_firewall_rules
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1).and_raise Errno::ECONNREFUSED
      expect { nx.wait_sshable }.to nap(1)
    end

    it "hops to create_billing_record if sshable" do
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "10.0.0.1/32")
      st.update(retval: Sequel.pg_jsonb({"msg" => "firewall rule is added"}))
      vm.incr_update_firewall_rules
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1)
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end

    it "hops to create_billing_record if ipv4 is not available" do
      st.update(retval: Sequel.pg_jsonb({"msg" => "firewall rule is added"}))
      vm.incr_update_firewall_rules
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

    it "deletes the GCE instance and destroys the vm" do
      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!)
      expect(compute_client).to receive(:delete).with(
        project: "test-gcp-project",
        zone: "hetzner-fsn1-a",
        instance: "testvm"
      ).and_return(op)

      expect { nx.destroy }.to exit({"msg" => "vm destroyed"})
    end

    it "handles already-deleted instances" do
      expect(compute_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect { nx.destroy }.to exit({"msg" => "vm destroyed"})
    end

    it "uses zone from VM strand frame when NIC is already destroyed" do
      st.stack.first["gcp_zone_suffix"] = "c"
      st.modified!(:stack)
      st.save_changes

      # Simulate NIC already destroyed
      nx.instance_variable_set(:@nic, nil)
      allow(vm).to receive(:nic).and_return(nil)

      op = instance_double(Gapic::GenericLRO::Operation)
      expect(op).to receive(:wait_until_done!)
      expect(compute_client).to receive(:delete).with(
        project: "test-gcp-project",
        zone: "hetzner-fsn1-c",
        instance: "testvm"
      ).and_return(op)

      expect { nx.destroy }.to exit({"msg" => "vm destroyed"})
    end
  end

  describe "helper methods" do
    it "returns e2-standard for standard family with various vcpu counts" do
      expect(nx.send(:gce_machine_type)).to eq("e2-standard-2")
    end

    it "rounds up to nearest e2-standard for non-power-of-2 vcpus" do
      vm.update(vcpus: 30)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("e2-standard-32")
    end

    it "uses n2-standard for vcpus above 32" do
      vm.update(vcpus: 60)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("n2-standard-64")
    end

    it "returns e2-standard-2 minimum for single vcpu" do
      vm.update(vcpus: 1)
      vm.reload
      expect(nx.send(:gce_machine_type)).to eq("e2-standard-2")
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

    it "returns per-project VPC name as the network name" do
      expect(nx.send(:gce_network_name)).to eq("ubicloud-proj-#{project.ubid}")
    end

    it "returns subnet name based on private subnet ubid" do
      expect(nx.send(:gce_subnet_name)).to start_with("ubicloud-")
    end

    it "returns default subnet name when nic is nil" do
      nic_double = instance_double(Nic, private_subnet: nil)
      nx.instance_variable_set(:@nic, nic_double)
      expect(nx.send(:gce_subnet_name)).to eq("default")
    end

    it "returns the GCP region from location name" do
      expect(nx.send(:gcp_region)).to eq("hetzner-fsn1")
    end
  end
end
