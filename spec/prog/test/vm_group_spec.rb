# frozen_string_literal: true

require "aws-sdk-ec2"
require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::VmGroup do
  subject(:vg_test) { described_class.new(st) }

  let(:st) { described_class.assemble(boot_images: ["ubuntu-noble", "debian-12"]) }

  describe ".assemble" do
    it "defaults to metal provider" do
      st = described_class.assemble(boot_images: ["ubuntu-noble"])
      expect(st.stack.first["provider"]).to eq("metal")
    end

    it "accepts a provider parameter" do
      st = described_class.assemble(boot_images: ["ubuntu-noble"], provider: "gcp")
      expect(st.stack.first["provider"]).to eq("gcp")
    end
  end

  describe "#start" do
    it "hops to setup_vms" do
      expect { vg_test.start }.to hop("setup_vms")
    end
  end

  describe "#setup_vms" do
    it "hops to wait_children_ready" do
      expect(vg_test).to receive(:update_stack).and_call_original
      expect { vg_test.setup_vms }.to hop("wait_vms")
      vm_images = vg_test.strand.stack.first["vms"].map { Vm[it].boot_image }
      expect(vm_images).to eq(["ubuntu-noble", "debian-12", "ubuntu-noble"])
    end

    it "provisions at least one vm for each boot image" do
      expect(vg_test).to receive(:update_stack).and_call_original
      expect(vg_test).to receive(:frame).and_return({
        "provider" => "metal",
        "test_slices" => true,
        "boot_images" => ["ubuntu-noble", "ubuntu-jammy", "debian-12", "almalinux-9"]
      }).at_least(:once)
      expect { vg_test.setup_vms }.to hop("wait_vms")
      vm_images = vg_test.strand.stack.first["vms"].map { Vm[it].boot_image }
      expect(vm_images).to eq(["ubuntu-noble", "ubuntu-jammy", "debian-12", "almalinux-9"])
    end

    it "hops to wait_children_ready if test_slices" do
      expect(vg_test).to receive(:update_stack).and_call_original
      expect(vg_test).to receive(:frame).and_return({
        "provider" => "metal",
        "storage_encrypted" => true,
        "test_reboot" => true,
        "test_slices" => true,
        "vms" => [],
        "boot_images" => ["ubuntu-noble", "ubuntu-jammy", "debian-12", "almalinux-9"]
      }).at_least(:once)
      expect { vg_test.setup_vms }.to hop("wait_vms")
    end

    it "sets up aws location and credentials" do
      expect(Config).to receive(:e2e_aws_access_key).and_return("access_key")
      expect(Config).to receive(:e2e_aws_secret_key).and_return("secret_key")
      allow(Aws::Credentials).to receive(:new).and_call_original
      allow(Aws::EC2::Client).to receive(:new).and_return(Aws::EC2::Client.new(stub_responses: true))
      aws_st = described_class.assemble(boot_images: ["ubuntu-noble"], provider: "aws")
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      LocationAwsAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
      aws_vg_test = described_class.new(aws_st)
      expect(aws_vg_test).to receive(:update_stack).and_call_original
      expect { aws_vg_test.setup_vms }.to hop("wait_vms")
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      expect(LocationCredential[location.id].access_key).to eq("access_key")
    end

    it "skips aws credential creation when credential already exists" do
      allow(Aws::Credentials).to receive(:new).and_call_original
      allow(Aws::EC2::Client).to receive(:new).and_return(Aws::EC2::Client.new(stub_responses: true))
      aws_st = described_class.assemble(boot_images: ["ubuntu-noble"], provider: "aws")
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      LocationAwsAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
      LocationCredential.create_with_id(location.id, access_key: "existing_key", secret_key: "existing_secret")
      aws_vg_test = described_class.new(aws_st)
      expect(aws_vg_test).to receive(:update_stack).and_call_original
      expect { aws_vg_test.setup_vms }.to hop("wait_vms")
      expect(LocationCredential[location.id].access_key).to eq("existing_key")
    end

    it "sets up gcp location" do
      expect(Config).to receive(:e2e_gcp_credentials_json).and_return("{}")
      expect(Config).to receive(:e2e_gcp_project_id).and_return("test-project")
      expect(Config).to receive(:e2e_gcp_service_account_email).and_return("test@test.iam.gserviceaccount.com")
      gcp_st = described_class.assemble(boot_images: ["ubuntu-noble"], provider: "gcp")
      gcp_vg_test = described_class.new(gcp_st)
      expect(gcp_vg_test).to receive(:update_stack).and_call_original
      expect { gcp_vg_test.setup_vms }.to hop("wait_vms")
    end

    it "skips gcp credential creation when credential already exists" do
      location = Location[provider: "gcp", project_id: nil]
      LocationCredential.create_with_id(location.id, credentials_json: "{}", project_id: "existing-project", service_account_email: "existing@test.iam.gserviceaccount.com")
      gcp_st = described_class.assemble(boot_images: ["ubuntu-noble"], provider: "gcp")
      gcp_vg_test = described_class.new(gcp_st)
      expect(gcp_vg_test).to receive(:update_stack).and_call_original
      expect { gcp_vg_test.setup_vms }.to hop("wait_vms")
      expect(LocationCredential[location.id].project_id).to eq("existing-project")
    end
  end

  describe "#wait_vms" do
    it "hops to verify_vms if vms are ready" do
      expect(vg_test).to receive(:frame).and_return({"vms" => ["111"]})
      expect(Vm).to receive(:[]).with("111").and_return(instance_double(Vm, display_state: "running"))
      expect { vg_test.wait_vms }.to hop("verify_vms")
    end

    it "naps if vms are not running" do
      expect(vg_test).to receive(:frame).and_return({"vms" => ["111"]})
      expect(Vm).to receive(:[]).with("111").and_return(instance_double(Vm, display_state: "creating"))
      expect { vg_test.wait_vms }.to nap(10)
    end
  end

  describe "#verify_vms" do
    it "runs tests for the first vm" do
      expect(vg_test).to receive(:frame).and_return({"vms" => ["111", "222"], "first_boot" => true}).at_least(:once)
      expect(vg_test).to receive(:bud).with(Prog::Test::Vm, {subject_id: "111", first_boot: true})
      expect(vg_test).to receive(:bud).with(Prog::Test::Vm, {subject_id: "222", first_boot: true})
      expect { vg_test.verify_vms }.to hop("wait_verify_vms")
    end
  end

  describe "#wait_verify_vms" do
    it "hops to hop_wait_verify_vms" do
      expect { vg_test.wait_verify_vms }.to hop("verify_host_capacity")
    end

    it "stays in wait_verify_vms" do
      Strand.create(parent_id: st.id, prog: "Test::Vm", label: "start", stack: [{}], lease: Time.now + 10)
      expect { vg_test.wait_verify_vms }.to nap(120)

      expect(st).to receive(:lock!).and_wrap_original do |m|
        # Pretend child strand updated schedule before lock.
        # After the lock, shouldn't be possible as the child
        # strand's update of the parent will block until
        # parent strand commits.
        st.this.update(schedule: Time.now - 1)
        m.call
      end
      expect { vg_test.wait_verify_vms }.to nap(0)
    end
  end

  describe "#verify_host_capacity" do
    it "hops to verify_vm_host_slices" do
      vm_host = instance_double(VmHost,
        total_cpus: 16,
        total_cores: 8,
        used_cores: 3,
        vms: [instance_double(Vm, cores: 2), instance_double(Vm, cores: 0)],
        slices: [instance_double(VmHostSlice, cores: 1)],
        cpus: [])
      expect(vg_test).to receive_messages(vm_host:, frame: {"verify_host_capacity" => true, "provider" => "metal"})
      expect { vg_test.verify_host_capacity }.to hop("verify_vm_host_slices")
    end

    it "skips if verify_host_capacity is not set" do
      expect(vg_test).to receive(:frame).and_return({"verify_host_capacity" => false, "provider" => "metal"})
      expect(vg_test).not_to receive(:vm_host)
      expect { vg_test.verify_host_capacity }.to hop("verify_vm_host_slices")
    end

    it "skips on cloud providers" do
      allow(vg_test).to receive(:frame).and_return({"verify_host_capacity" => true, "provider" => "aws"})
      expect(vg_test).not_to receive(:vm_host)
      expect { vg_test.verify_host_capacity }.to hop("verify_vm_host_slices")
    end

    it "fails if used cores do not match allocated VMs" do
      vm_host = instance_double(VmHost,
        total_cpus: 16,
        total_cores: 8,
        used_cores: 5,
        vms: [instance_double(Vm, cores: 2), instance_double(Vm, cores: 0)],
        slices: [instance_double(VmHostSlice, cores: 1)],
        cpus: [])
      expect(vg_test).to receive_messages(vm_host:, frame: {"verify_host_capacity" => true, "provider" => "metal"})

      strand = instance_double(Strand)
      allow(vg_test).to receive_messages(strand:)
      expect(strand).to receive(:update).with(exitval: {msg: "Host used cores does not match the allocated VMs cores (vm_cores=2, slice_cores=1, used_cores=5)"})

      expect { vg_test.verify_host_capacity }.to hop("failed")
    end
  end

  describe "#verify_vm_host_slices" do
    it "runs tests on vm host slices" do
      expect(vg_test).to receive(:frame).and_return({"test_slices" => true, "provider" => "metal", "vms" => ["111", "222", "333"]}).at_least(:once)
      slice1 = instance_double(VmHostSlice, id: "456")
      slice2 = instance_double(VmHostSlice, id: "789")
      expect(Vm).to receive(:[]).with("111").and_return(instance_double(Vm, vm_host_slice: slice1))
      expect(Vm).to receive(:[]).with("222").and_return(instance_double(Vm, vm_host_slice: slice2))
      expect(Vm).to receive(:[]).with("333").and_return(instance_double(Vm, vm_host_slice: nil))

      expect { vg_test.verify_vm_host_slices }.to hop("start", "Test::VmHostSlices")
    end

    it "hops to verify_storage_rpc if tests are done" do
      allow(vg_test).to receive(:frame).and_return({"test_slices" => true, "provider" => "metal"})
      expect(vg_test.strand).to receive(:retval).and_return({"msg" => "Verified VM Host Slices!"})
      expect { vg_test.verify_vm_host_slices }.to hop("verify_storage_rpc")
    end

    it "skips on cloud providers" do
      allow(vg_test).to receive(:frame).and_return({"test_slices" => true, "provider" => "gcp"})
      expect { vg_test.verify_vm_host_slices }.to hop("verify_storage_rpc")
    end
  end

  describe "#verify_storage_rpc" do
    it "verifies vhost-block-backend version for each vm using RPC" do
      command = {command: "version"}.to_json
      expected_response = {version: Config.vhost_block_backend_version.delete_prefix("v")}.to_json + "\n"
      vm_host = instance_double(VmHost, sshable: Sshable.create)
      allow(vg_test).to receive(:vm_host).and_return(vm_host)
      vm1 = instance_double(Vm, id: "vm1", inhost_name: "vm123456")
      vm2 = instance_double(Vm, id: "vm2", inhost_name: "vm234567")
      expect(vg_test).to receive(:frame).and_return({"provider" => "metal", "vms" => ["vm1", "vm2"]}).at_least(:once)
      expect(Vm).to receive(:[]).with("vm1").and_return(vm1)
      expect(Vm).to receive(:[]).with("vm2").and_return(vm2)

      expect(vm_host.sshable).to receive(:_cmd).with("sudo nc -U /var/storage/vm123456/0/rpc.sock -q 0", stdin: command).and_return(expected_response)
      expect(vm_host.sshable).to receive(:_cmd).with("sudo nc -U /var/storage/vm234567/0/rpc.sock -q 0", stdin: command).and_return(expected_response)

      expect { vg_test.verify_storage_rpc }.to hop("verify_firewall_rules")
    end

    it "fails if unable to get vhost-block-backend version using RPC" do
      command = {command: "version"}.to_json
      sshable = Sshable.create
      vm_host = instance_double(VmHost, sshable:)
      allow(vg_test).to receive(:vm_host).and_return(vm_host)
      vm1 = instance_double(Vm, id: "vm1", inhost_name: "vm123456")
      expect(vg_test).to receive(:frame).and_return({"provider" => "metal", "vms" => ["vm1"]}).at_least(:once)
      expect(Vm).to receive(:[]).with("vm1").and_return(vm1)

      expect(vm_host.sshable).to receive(:_cmd).with("sudo nc -U /var/storage/vm123456/0/rpc.sock -q 0", stdin: command).and_return("{\"error\": \"some error\"}\n")

      expect(vg_test.strand).to receive(:update).with(exitval: {msg: "Failed to get vhost-block-backend version for VM vm1 using RPC"})
      expect { vg_test.verify_storage_rpc }.to hop("failed")
    end

    it "skips RPC verification on cloud providers" do
      expect(vg_test).to receive(:frame).and_return({"provider" => "aws"}).at_least(:once)
      expect(vg_test).not_to receive(:vm_host)
      expect { vg_test.verify_storage_rpc }.to hop("verify_firewall_rules")
    end
  end

  describe "#verify_firewall_rules" do
    it "hops to test_reboot if tests are done" do
      expect(vg_test.strand).to receive(:retval).and_return({"msg" => "Verified Firewall Rules!"})
      expect { vg_test.verify_firewall_rules }.to hop("verify_connected_subnets")
    end

    it "runs tests for the first firewall" do
      subnet = instance_double(PrivateSubnet, firewalls: [instance_double(Firewall, id: "fw_id")])
      expect(PrivateSubnet).to receive(:[]).and_return(subnet)
      expect(vg_test).to receive(:frame).and_return({"subnets" => [subnet]})
      expect { vg_test.verify_firewall_rules }.to hop("start", "Test::FirewallRules")
    end
  end

  describe "#verify_connected_subnets" do
    it "hops to test_reboot if tests are done on metal" do
      expect(vg_test.strand).to receive(:retval).and_return({"msg" => "Verified Connected Subnets!"})
      expect { vg_test.verify_connected_subnets }.to hop("test_reboot")
    end

    it "hops to destroy_resources if tests are done on cloud provider" do
      expect(vg_test.strand).to receive(:retval).and_return({"msg" => "Verified Connected Subnets!"})
      allow(vg_test).to receive(:frame).and_return({"test_reboot" => true, "first_boot" => true, "provider" => "aws"})
      expect { vg_test.verify_connected_subnets }.to hop("destroy_resources")
    end

    it "runs tests for the first connected subnet" do
      prj = Project.create(name: "project-1")
      ps1 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps1", location_id: Location::HETZNER_FSN1_ID).subject
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps2", location_id: Location::HETZNER_FSN1_ID).subject
      expect(vg_test).to receive(:frame).and_return({"subnets" => [ps1.id, ps2.id], "provider" => "metal"}).at_least(:once)
      expect { vg_test.verify_connected_subnets }.to hop("start", "Test::ConnectedSubnets")
    end

    it "runs tests for the second connected subnet" do
      prj = Project.create(name: "project-1")
      ps1 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps1", location_id: Location::HETZNER_FSN1_ID).subject
      expect(ps1).to receive(:vms).and_return([instance_double(Vm, id: "vm1"), instance_double(Vm, id: "vm2")]).at_least(:once)
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps2", location_id: Location::HETZNER_FSN1_ID).subject
      expect(PrivateSubnet).to receive(:[]).and_return(ps1, ps2)
      expect(vg_test).to receive(:frame).and_return({"subnets" => [ps1.id, ps2.id], "provider" => "metal"}).at_least(:once)
      expect { vg_test.verify_connected_subnets }.to hop("start", "Test::ConnectedSubnets")
    end

    it "skips connected subnet tests on cloud providers" do
      allow(vg_test).to receive(:frame).and_return({"provider" => "gcp"})
      expect { vg_test.verify_connected_subnets }.to hop("destroy_resources")
    end

    it "hops to destroy_resources if tests are done and reboot is not set" do
      expect(vg_test.strand).to receive(:retval).and_return({"msg" => "Verified Connected Subnets!"})
      expect(vg_test).to receive(:frame).and_return({"test_reboot" => false})
      expect { vg_test.verify_connected_subnets }.to hop("destroy_resources")
    end
  end

  describe "#test_reboot" do
    it "hops to wait_reboot" do
      expect(vg_test).to receive(:vm_host).and_return(instance_double(VmHost)).twice
      expect(vg_test.vm_host).to receive(:incr_reboot).with(no_args)
      expect { vg_test.test_reboot }.to hop("wait_reboot")
    end
  end

  describe "#wait_reboot" do
    before do
      allow(vg_test).to receive(:vm_host).and_return(instance_double(VmHost))
      allow(vg_test.vm_host).to receive(:strand).and_return(instance_double(Strand))
    end

    it "naps if strand is busy" do
      expect(vg_test.vm_host.strand).to receive(:label).and_return("reboot")
      expect { vg_test.wait_reboot }.to nap(20)
    end

    it "runs vm tests if reboot done" do
      expect(vg_test.vm_host.strand).to receive(:label).and_return("wait")
      expect(vg_test.vm_host.strand).to receive(:semaphores).and_return([])
      expect { vg_test.wait_reboot }.to hop("verify_vms")
    end
  end

  describe "#destroy_resources" do
    it "hops to wait_resources_destroyed" do
      allow(vg_test).to receive(:frame).and_return({"vms" => ["vm_id"], "subnets" => ["subnet_id"]}).twice
      expect(Vm).to receive(:[]).with("vm_id").and_return(instance_double(Vm, incr_destroy: nil))
      expect(PrivateSubnet).to receive(:[]).with("subnet_id").and_return(instance_double(PrivateSubnet, incr_destroy: nil, firewalls: []))
      expect { vg_test.destroy_resources }.to hop("wait_resources_destroyed")
    end
  end

  describe "#wait_resources_destroyed" do
    it "hops to finish if all resources are destroyed" do
      allow(vg_test).to receive(:frame).and_return({"vms" => ["vm_id"], "subnets" => ["subnet_id"]}).twice
      expect(Vm).to receive(:[]).with("vm_id").and_return(nil)
      expect(PrivateSubnet).to receive(:[]).with("subnet_id").and_return(nil)

      expect { vg_test.wait_resources_destroyed }.to hop("finish")
    end

    it "naps if all resources are not destroyed yet" do
      allow(vg_test).to receive(:frame).and_return({"vms" => ["vm_id"], "subnets" => ["subnet_id"]}).twice
      expect(Vm).to receive(:[]).with("vm_id").and_return(instance_double(Vm))
      expect { vg_test.wait_resources_destroyed }.to nap(5)
    end
  end

  describe "#finish" do
    it "exits" do
      project = Project.create(name: "project-1")
      allow(vg_test).to receive(:frame).and_return({"project_id" => project.id})
      expect { vg_test.finish }.to exit({"msg" => "VmGroup tests finished!"})
    end
  end

  describe "#failed" do
    it "naps" do
      expect { vg_test.failed }.to nap(15)
    end
  end

  describe "#vm_host" do
    it "returns first VM's host" do
      vm_host = create_vm_host
      vm = create_vm(vm_host_id: vm_host.id)
      expect(vg_test).to receive(:frame).and_return({"vms" => [vm.id]})
      expect(vg_test.vm_host).to eq(vm_host)
    end
  end
end
