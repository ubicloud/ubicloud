# frozen_string_literal: true

RSpec.describe Prog::Aws::Instance do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create_with_id(prog: "Aws::Instance", stack: [{"subject_id" => vm.id}], label: "start")
  }

  let(:vm) {
    prj = Project.create_with_id(name: "test-prj")
    loc = Location.create_with_id(name: "us-east-1", provider: "aws", project_id: prj.id, display_name: "aws-us-east-1", ui_name: "AWS US East 1", visible: true)
    LocationCredential.create_with_id(access_key: "test-access-key", secret_key: "test-secret-key") { it.id = loc.id }
    Prog::Vm::Nexus.assemble("dummy-public key", prj.id, location_id: loc.id, unix_user: "test-user-aws", boot_image: "ami-030c060f85668b37d").subject
  }

  let(:client) {
    Aws::EC2::Client.new(stub_responses: true)
  }

  let(:user_data) {
    <<~USER_DATA
#!/bin/bash
custom_user="test-user-aws"
# Create the custom user
adduser $custom_user --disabled-password --gecos ""
# Add the custom user to the sudo group
usermod -aG sudo $custom_user
# disable password for the custom user
echo "$custom_user ALL=(ALL:ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$custom_user
# Set up SSH access for the custom user
mkdir -p /home/$custom_user/.ssh
cp /home/ubuntu/.ssh/authorized_keys /home/$custom_user/.ssh/
chown -R $custom_user:$custom_user /home/$custom_user/.ssh
chmod 700 /home/$custom_user/.ssh
chmod 600 /home/$custom_user/.ssh/authorized_keys
echo dummy-public-key > /home/$custom_user/.ssh/authorized_keys
usermod -L ubuntu
    USER_DATA
  }

  before do
    allow(nx).to receive(:vm).and_return(vm)
    expect(Aws::EC2::Client).to receive(:new).with(access_key_id: "test-access-key", secret_access_key: "test-secret-key", region: "us-east-1").and_return(client)
  end

  describe "#start" do
    it "creates an instance" do
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg"}])
      expect(vm).to receive(:vcpus).and_return(2)
      expect(vm).to receive(:sshable).and_return(instance_double(Sshable, keys: [instance_double(SshKey, public_key: "dummy-public-key")]))

      expect(client).to receive(:run_instances).with({
        image_id: "ami-030c060f85668b37d",
        instance_type: "m6id.large",
        block_device_mappings: [
          {
            device_name: "/dev/sda1",
            ebs: {
              encrypted: true,
              delete_on_termination: true,
              iops: 3000,
              volume_size: 40,
              volume_type: "gp3",
              throughput: 125
            }
          }
        ],
        network_interfaces: [
          {
            network_interface_id: vm.nics.first.name,
            device_index: 0
          }
        ],
        private_dns_name_options: {
          hostname_type: "ip-name",
          enable_resource_name_dns_a_record: false,
          enable_resource_name_dns_aaaa_record: false
        },
        min_count: 1,
        max_count: 1,
        user_data: Base64.encode64(user_data),
        tag_specifications: [{resource_type: "instance", tags: [{key: "Ubicloud", value: "true"}]}]
      }).and_call_original
      expect(vm).to receive(:update).with(name: "i-0123456789abcdefg")
      expect { nx.start }.to hop("wait_instance_created")
    end
  end

  describe "#wait_instance_created" do
    before do
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "running"}, network_interfaces: [{association: {public_ip: "1.2.3.4"}, ipv_6_addresses: [{ipv_6_address: "2a01:4f8:173:1ed3:aa7c::/79"}]}]}]}])
    end

    it "updates the vm with the instance id" do
      time = Time.now
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      expect(vm.strand).to receive(:stack).and_return([{"storage_volumes" => [{"boot" => false, "size_gib" => 10}]}], label: "start").at_least(:once)
      expect(client).to receive(:describe_instances).with({filters: [{name: "instance-id", values: [vm.name]}, {name: "tag:Ubicloud", values: ["true"]}]}).and_call_original
      expect(vm).to receive(:update).with(cores: 1, allocated_at: time, ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
      expect { nx.wait_instance_created }.to exit({"msg" => "vm created"})
      expect(VmStorageVolume.count).to eq(1)
      expect(VmStorageVolume.first).to have_attributes(size_gib: 10, boot: false, use_bdev_ubi: false, disk_index: 1)
    end

    it "doesn't create vm_storage_volumes if there are no storage volumes" do
      time = Time.now
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      sshable = instance_double(Sshable)
      expect(vm).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:update).with(host: "1.2.3.4")
      expect(vm.strand).to receive(:stack).and_return([{"storage_volumes" => [{"boot" => true, "size_gib" => 10}]}], label: "start").at_least(:once)
      expect(vm).to receive(:update).with(cores: 1, allocated_at: time, ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
      expect { nx.wait_instance_created }.to exit({"msg" => "vm created"})
      expect(VmStorageVolume.count).to eq(0)
    end

    it "naps if the instance is not running" do
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "pending"}}]}])
      expect { nx.wait_instance_created }.to nap(1)
    end
  end

  describe "#destroy" do
    it "deletes the instance" do
      expect(client).to receive(:terminate_instances).with({instance_ids: [vm.name]})
      expect { nx.destroy }.to exit({"msg" => "vm destroyed"})
    end
  end
end
