# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Vm::Nexus do
  subject(:nx) {
    described_class.new(vm.strand).tap {
      it.instance_variable_set(:@vm, vm)
      it.instance_variable_set(:@host, vm_host)
    }
  }

  let(:st) { vm.strand }
  let(:vm_host) { create_vm_host(used_cores: 2, total_hugepages_1g: 375, used_hugepages_1g: 16) }
  let(:sshable) { vm_host.sshable }
  let(:vm) {
    vm = Vm.create_with_id(
      "2464de61-7501-8374-9ab0-416caebe31da",
      name: "dummy-vm",
      unix_user: "ubi",
      public_key: "ssh key",
      boot_image: "ubuntu-jammy",
      family: "standard",
      cores: 1,
      vcpus: 2,
      cpu_percent_limit: 200,
      cpu_burst_percent_limit: 0,
      memory_gib: 8,
      arch: "x64",
      location_id: Location::HETZNER_FSN1_ID,
      created_at: Time.now,
      project_id: project.id,
      vm_host_id: vm_host.id
    )
    Strand.create_with_id(vm.id, prog: "Vm::Nexus", label: "start")
    vm
  }
  let(:project) { Project.create(name: "default") }
  let(:private_subnet) {
    PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "1.1.1.0/26", state: "waiting", project_id: project.id)
  }
  let(:nic) {
    Nic.create(private_subnet_id: private_subnet.id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
      private_ipv4: "10.0.0.1",
      mac: "00:00:00:00:00:00",
      encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
      name: "default-nic",
      state: "active")
  }

  describe ".assemble" do
    it "fails if there is no project" do
      expect {
        described_class.assemble("some_ssh key", "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "No existing project"
    end

    it "fails if location doesn't exist" do
      expect {
        described_class.assemble("some_ssh key", project.id, location_id: nil)
      }.to raise_error RuntimeError, "No existing location"
    end

    it "creates Subnet and Nic if not passed" do
      expect {
        described_class.assemble("some_ssh key", project.id)
      }.to change(PrivateSubnet, :count).from(0).to(1)
        .and change(Nic, :count).from(0).to(1)
    end

    it "creates Nic if only subnet_id is passed" do
      expect {
        described_class.assemble("some_ssh key", project.id, private_subnet_id: private_subnet.id)
      }.to change(Nic, :count).from(0).to(1)
      expect(PrivateSubnet.count).to eq(1)
    end

    it "adds the VM to a private subnet if nic_id is passed" do
      expect(Prog::Vnet::SubnetNexus).not_to receive(:assemble)
      expect(Prog::Vnet::NicNexus).not_to receive(:assemble)
      described_class.assemble("some_ssh key", project.id, nic_id: nic.id, location_id: Location::HETZNER_FSN1_ID)
    end

    it "creates with default storage size from vm size" do
      st = described_class.assemble("some_ssh key", project.id)
      expect(st.stack.first["storage_volumes"].first["size_gib"]).to eq(Option::VmSizes.first.storage_size_options.first)
    end

    it "creates with custom storage size if provided" do
      st = described_class.assemble("some_ssh key", project.id, storage_volumes: [{size_gib: 40}])
      expect(st.stack.first["storage_volumes"].first["size_gib"]).to eq(40)
    end

    it "fails if given nic_id is not valid" do
      expect {
        described_class.assemble("some_ssh key", project.id, nic_id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "Given nic doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "fails if given subnet_id is not valid" do
      expect {
        described_class.assemble("some_ssh key", project.id, private_subnet_id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "Given subnet doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "fails if nic is assigned to a different vm" do
      nic.update(vm_id: vm.id)
      expect {
        described_class.assemble("some_ssh key", project.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic is assigned to a VM already"
    end

    it "fails if nic subnet is in another location" do
      private_subnet.update(location_id: Location::LEASEWEB_WDC02_ID)
      expect {
        described_class.assemble("some_ssh key", project.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic is created in a different location"
    end

    it "fails if subnet of nic belongs to another project" do
      private_subnet.update(project_id: Project.create(name: "project-2").id)
      expect {
        described_class.assemble("some_ssh key", project.id, nic_id: nic.id)
      }.to raise_error RuntimeError, "Given nic is not available in the given project"
    end

    it "fails if subnet belongs to another project" do
      private_subnet.update(project_id: Project.create(name: "project-2").id)
      expect {
        described_class.assemble("some_ssh key", project.id, private_subnet_id: private_subnet.id)
      }.to raise_error RuntimeError, "Given subnet is not available in the given project"
    end

    it "allows if subnet belongs to another project and allow_private_subnet_in_other_project argument is given" do
      private_subnet.update(project_id: Project.create(name: "project-2").id)
      vm = described_class.assemble("some_ssh key", project.id, private_subnet_id: private_subnet.id, allow_private_subnet_in_other_project: true).subject
      expect(vm.private_subnets.map(&:id)).to eq [private_subnet.id]
    end

    it "creates arm64 vm with double core count and 3.2GB memory per core" do
      st = described_class.assemble("some_ssh key", project.id, size: "standard-4", arch: "arm64")
      expect(st.subject.vcpus).to eq(4)
      expect(st.subject.memory_gib).to eq(12)
    end

    it "requests as many gpus as specified" do
      st = described_class.assemble("some_ssh key", project.id, size: "standard-2", gpu_count: 2)
      expect(st.stack.first["gpu_count"]).to eq(2)
    end

    it "requests at least a single gpu for standard-gpu-6" do
      st = described_class.assemble("some_ssh key", project.id, size: "standard-gpu-6")
      expect(st.stack.first["gpu_count"]).to eq(1)
    end

    it "requests no gpus by default" do
      st = described_class.assemble("some_ssh key", project.id, size: "standard-2")
      expect(st.stack.first["gpu_count"]).to eq(0)
    end

    it "creates correct number of storage volumes for storage optimized instance types" do
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "us-west-2", ui_name: "us-west-2", visible: true)
      storage_volumes = [
        {encrypted: true, size_gib: 30},
        {encrypted: true, size_gib: 7500}
      ]

      vm = described_class.assemble("some_ssh key", project.id, location_id: loc.id, size: "i8g.8xlarge", arch: "arm64", storage_volumes:).subject
      expect(vm.vm_storage_volumes.count).to eq(3)
    end

    it "hops to start_aws if location is aws" do
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "us-west-2", ui_name: "us-west-2", visible: true)
      st = described_class.assemble("some_ssh key", project.id, location_id: loc.id)
      expect(st.label).to eq("start")
    end

    it "fails if same host is forced and excluded" do
      expect {
        described_class.assemble("some_ssh key", project.id,
          force_host_id: "some-vm-host-id", exclude_host_ids: ["some-vm-host-id"])
      }.to raise_error RuntimeError, "Cannot force and exclude the same host"
    end
  end

  describe ".assemble_with_sshable" do
    it "calls .assemble with generated ssh key" do
      st_id = "eb3dbcb3-2c90-8b74-8fb4-d62a244d7ae5"
      expect(SshKey).to receive(:generate).and_return(instance_double(SshKey, public_key: "public", keypair: "pair"))
      st = Strand.new(id: st_id)
      expect(described_class).to receive(:assemble) do |public_key, project_id, **kwargs|
        expect(public_key).to eq("public")
        expect(project_id).to eq(project.id)
        expect(kwargs[:name]).to be_nil
        expect(kwargs[:size]).to eq("new_size")
      end.and_return(st)
      expect(Sshable).to receive(:create_with_id).with(st, host: "temp_#{st_id}", raw_private_key_1: "pair", unix_user: "rhizome")

      described_class.assemble_with_sshable(project.id, size: "new_size")
    end
  end
end
