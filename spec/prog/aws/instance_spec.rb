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
    loc = Location.create_with_id(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)
    LocationCredential.create_with_id(access_key: "test-access-key", secret_key: "test-secret-key") { it.id = loc.id }
    storage_volumes = [
      {encrypted: true, size_gib: 30},
      {encrypted: true, size_gib: 3800}
    ]
    Prog::Vm::Nexus.assemble("dummy-public key", prj.id, location_id: loc.id, unix_user: "test-user-aws", boot_image: "ami-030c060f85668b37d", name: "testvm", size: "m6gd.large", arch: "arm64", storage_volumes:).subject
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
    allow(Aws::EC2::Client).to receive(:new).with(access_key_id: "test-access-key", secret_access_key: "test-secret-key", region: "us-west-2").and_return(client)
  end

  describe "#start" do
    it "creates an instance" do
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}]}])
      client.stub_responses(:describe_subnets, subnets: [{availability_zone_id: "use1-az1"}])
      expect(vm).to receive(:vcpus).and_return(2)
      expect(vm).to receive(:sshable).and_return(instance_double(Sshable, keys: [instance_double(SshKey, public_key: "dummy-public-key")]))

      expect(vm.nics.first).to receive(:nic_aws_resource).and_return(instance_double(NicAwsResource, network_interface_id: "eni-0123456789abcdefg"))
      expect(client).to receive(:run_instances).with({
        image_id: "ami-030c060f85668b37d",
        instance_type: "m6gd.large",
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
            network_interface_id: "eni-0123456789abcdefg",
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
        tag_specifications: Util.aws_tag_specifications("instance", vm.name)
      }).and_call_original
      expect(AwsInstance).to receive(:create).with(instance_id: "i-0123456789abcdefg", az_id: "use1-az1")
      expect { nx.start }.to hop("wait_instance_created")
    end
  end

  describe "#wait_instance_created" do
    before do
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "running"}, network_interfaces: [{association: {public_ip: "1.2.3.4"}, ipv_6_addresses: [{ipv_6_address: "2a01:4f8:173:1ed3:aa7c::/79"}]}]}]}])
    end

    it "updates the vm" do
      time = Time.now
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      expect(client).to receive(:describe_instances).with({filters: [{name: "instance-id", values: ["i-0123456789abcdefg"]}, {name: "tag:Ubicloud", values: ["true"]}]}).and_call_original
      expect(vm).to receive(:update).with(cores: 1, allocated_at: time, ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
      expect(vm).to receive(:aws_instance).and_return(instance_double(AwsInstance, instance_id: "i-0123456789abcdefg"))
      expect { nx.wait_instance_created }.to exit({"msg" => "vm created"})
    end

    it "updates the vm with the instance id and updates ip according to the sshable" do
      time = Time.now
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      sshable = instance_double(Sshable)
      expect(vm).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:update).with(host: "1.2.3.4")
      expect(vm).to receive(:aws_instance).and_return(instance_double(AwsInstance, instance_id: "i-0123456789abcdefg"))
      expect(vm).to receive(:update).with(cores: 1, allocated_at: time, ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
      expect { nx.wait_instance_created }.to exit({"msg" => "vm created"})
    end

    it "naps if the instance is not running" do
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "pending"}}]}])
      expect(vm).to receive(:aws_instance).and_return(instance_double(AwsInstance, instance_id: "i-0123456789abcdefg"))
      expect { nx.wait_instance_created }.to nap(1)
    end
  end

  describe "#destroy" do
    it "deletes the instance" do
      aws_instance = instance_double(AwsInstance, instance_id: "i-0123456789abcdefg")
      expect(aws_instance).to receive(:destroy)
      expect(vm).to receive(:aws_instance).and_return(aws_instance).at_least(:once)
      expect(client).to receive(:terminate_instances).with({instance_ids: ["i-0123456789abcdefg"]})
      expect { nx.destroy }.to exit({"msg" => "vm destroyed"})
    end

    it "pops directly if there is no aws_instance" do
      expect(vm).to receive(:aws_instance).and_return(nil)
      expect { nx.destroy }.to exit({"msg" => "vm destroyed"})
    end
  end
end
