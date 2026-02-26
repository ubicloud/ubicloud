# frozen_string_literal: true

require "aws-sdk-ec2"
require "aws-sdk-iam"

RSpec.describe Prog::Vm::Aws::Nexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    vm.strand
  }

  let(:project) { Project.create(name: "test-prj") }

  let(:location) {
    Location.create(name: "us-west-2", provider: "aws", project_id: project.id,
      display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)
  }

  let(:location_credential) {
    loc = LocationCredential.create_with_id(location, access_key: "test-access-key", secret_key: "test-secret-key")
    LocationAwsAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
    loc
  }

  let(:storage_volumes) {
    [{encrypted: true, size_gib: 30}, {encrypted: true, size_gib: 3800}]
  }

  let(:vm_params) {
    {location_id: location.id, unix_user: "test-user-aws", boot_image: "ami-030c060f85668b37d",
     name: "testvm", size: "m6gd.large", arch: "arm64", storage_volumes:}
  }

  let(:vm) {
    location_credential  # force creation
    Prog::Vm::Nexus.assemble_with_sshable(project.id, **vm_params).subject
  }

  let(:vm_without_sshable) {
    location_credential
    Prog::Vm::Nexus.assemble("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI", project.id, **vm_params).subject
  }

  let(:aws_instance) { AwsInstance.create_with_id(vm, instance_id: "i-0123456789abcdefg") }

  let(:nic_aws_resource) {
    NicAwsResource.create_with_id(vm.nics.first, network_interface_id: "eni-0123456789abcdefg")
  }

  let(:client) { Aws::EC2::Client.new(stub_responses: true) }

  let(:iam_client) { Aws::IAM::Client.new(stub_responses: true) }

  let(:user_data) {
    public_key = vm.sshable.keys.first.public_key.shellescape
    <<~USER_DATA
#!/bin/bash
custom_user="#{vm.unix_user}"
if [ ! -d /home/$custom_user ]; then
  adduser $custom_user --disabled-password --gecos ""
  usermod -aG sudo $custom_user
  echo "$custom_user ALL=(ALL:ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$custom_user
  mkdir -p /home/$custom_user/.ssh
  cp /home/ubuntu/.ssh/authorized_keys /home/$custom_user/.ssh/
  chown -R $custom_user:$custom_user /home/$custom_user/.ssh
  chmod 700 /home/$custom_user/.ssh
  chmod 600 /home/$custom_user/.ssh/authorized_keys
fi
echo #{public_key} > /home/$custom_user/.ssh/authorized_keys
usermod -L ubuntu
    USER_DATA
  }

  before do
    allow(Aws::EC2::Client).to receive(:new).with(credentials: anything, region: "us-west-2").and_return(client)
    allow(Aws::IAM::Client).to receive(:new).with(credentials: anything, region: "us-west-2").and_return(iam_client)
  end

  describe ".assemble" do
    let(:assemble_loc) {
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "us-west-2", ui_name: "us-west-2", visible: true)
      LocationCredential.create_with_id(loc.id, access_key: "test-access-key", secret_key: "test-secret-key")
      LocationAwsAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
      loc
    }

    it "creates correct number of storage volumes for storage optimized instance types" do
      storage_volumes = [
        {encrypted: true, size_gib: 30},
        {encrypted: true, size_gib: 7500}
      ]

      vm = Prog::Vm::Nexus.assemble("some_ssh key", project.id, location_id: assemble_loc.id, size: "i8g.8xlarge", arch: "arm64", storage_volumes:).subject
      expect(vm.vm_storage_volumes.count).to eq(3)
    end

    it "hops to start_aws if location is aws" do
      st = Prog::Vm::Nexus.assemble("some_ssh key", project.id, location_id: assemble_loc.id)
      expect(st.label).to eq("start")
    end

    it "gives correct max_disk_size for vm family" do
      vm = Prog::Vm::Nexus.assemble("some_ssh key", project.id, location_id: assemble_loc.id, size: "i7ie.24xlarge").subject
      expect(vm.vm_storage_volumes.count).to eq(8)
      expect(vm.vm_storage_volumes.sum { it.size_gib }).to eq(60000)
    end

    it "gives correct size even when volume size smaller than max disk size" do
      vm = Prog::Vm::Nexus.assemble("some_ssh key", project.id, location_id: assemble_loc.id, size: "i7ie.large").subject
      expect(vm.vm_storage_volumes.count).to eq(1)
      expect(vm.vm_storage_volumes.sum { it.size_gib }).to equal(1250)
    end

    it "gives correct max_disk_size for vm family with specialized disk size" do
      vm = Prog::Vm::Nexus.assemble("some_ssh key", project.id, location_id: assemble_loc.id, size: "i7ie.2xlarge").subject
      expect(vm.vm_storage_volumes.count).to eq(2)
      expect(vm.vm_storage_volumes.sum { it.size_gib }).to equal(5000)
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

    it "creates a role for instance" do
      vm.nics.first.strand.update(label: "wait")
      iam_client.stub_responses(:create_role, {role: {role_name: vm.name, path: "/", role_id: "ROLE123", arn: "arn:aws:iam::123456789012:role/#{vm.name}", create_date: Time.now}})
      expect(iam_client).to receive(:create_role).with({
        role_name: vm.name,
        assume_role_policy_document: {
          Version: "2012-10-17",
          Statement: [
            {
              Effect: "Allow",
              Principal: {Service: "ec2.amazonaws.com"},
              Action: "sts:AssumeRole"
            }
          ]
        }.to_json
      }).and_call_original

      expect { nx.start }.to hop("create_role_policy")
    end

    it "hops to create_role_policy if role already exists" do
      vm.nics.first.strand.update(label: "wait")
      expect(iam_client).to receive(:create_role).with({role_name: vm.name, assume_role_policy_document: {
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Principal: {Service: "ec2.amazonaws.com"},
            Action: "sts:AssumeRole"
          }
        ]
      }.to_json}).and_raise(Aws::IAM::Errors::EntityAlreadyExists.new(nil, "EntityAlreadyExists"))
      expect { nx.start }.to hop("create_role_policy")
    end

    it "hops to create_instance if it's a runner instance" do
      vm.nics.first.strand.update(label: "wait")
      vm.update(unix_user: "runneradmin")
      expect { nx.start }.to hop("create_instance")
    end
  end

  describe "#create_role_policy" do
    it "creates a role policy" do
      iam_client.stub_responses(:create_policy, {})
      expect(iam_client).to receive(:create_policy).with({
        policy_name: "#{vm.name}-cw-agent-policy",
        policy_document: {
          Version: "2012-10-17",
          Statement: [
            {
              Effect: "Allow",
              Action: [
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:CreateLogGroup"
              ],
              Resource: [
                "arn:aws:logs:*:*:log-group:/#{vm.name}/auth:log-stream:*",
                "arn:aws:logs:*:*:log-group:/#{vm.name}/postgresql:log-stream:*"
              ]
            },
            {
              Effect: "Allow",
              Action: "logs:DescribeLogStreams",
              Resource: [
                "arn:aws:logs:*:*:log-group:/#{vm.name}/auth:*",
                "arn:aws:logs:*:*:log-group:/#{vm.name}/postgresql:*"
              ]
            }
          ]
        }.to_json
      }).and_call_original

      expect { nx.create_role_policy }.to hop("attach_role_policy")
    end

    it "hops to attach_role_policy if policy already exists" do
      expect(iam_client).to receive(:create_policy).and_raise(Aws::IAM::Errors::EntityAlreadyExists.new(nil, "EntityAlreadyExists"))
      expect { nx.create_role_policy }.to hop("attach_role_policy")
    end
  end

  describe "#attach_role_policy" do
    it "attaches role policy" do
      iam_client.stub_responses(:attach_role_policy, {})
      iam_client.stub_responses(:list_policies, policies: [{policy_name: "#{vm.name}-cw-agent-policy", arn: "arn:aws:iam::aws:policy/#{vm.name}-cw-agent-policy"}])
      expect(iam_client).to receive(:attach_role_policy).with({
        role_name: vm.name,
        policy_arn: "arn:aws:iam::aws:policy/#{vm.name}-cw-agent-policy"
      }).and_call_original

      expect { nx.attach_role_policy }.to hop("create_instance_profile")
    end

    it "hops to create_instance_profile if policy already exists" do
      iam_client.stub_responses(:list_policies, policies: [{policy_name: "#{vm.name}-cw-agent-policy", arn: "arn:aws:iam::aws:policy/#{vm.name}-cw-agent-policy"}])
      expect(iam_client).to receive(:list_policies).with(scope: "Local", marker: nil, max_items: 100).and_call_original
      expect(iam_client).to receive(:attach_role_policy).and_raise(Aws::IAM::Errors::EntityAlreadyExists.new(nil, "EntityAlreadyExists"))
      expect { nx.attach_role_policy }.to hop("create_instance_profile")
    end
  end

  describe "#create_instance_profile" do
    it "creates an instance profile" do
      iam_client.stub_responses(:create_instance_profile, instance_profile: {instance_profile_name: "#{vm.name}-instance-profile", instance_profile_id: "test-id", path: "/", roles: [], arn: "arn:aws:iam::123456789012:instance-profile/#{vm.name}-instance-profile", create_date: Time.now})
      expect(iam_client).to receive(:create_instance_profile).with({
        instance_profile_name: "#{vm.name}-instance-profile"
      }).and_call_original

      expect { nx.create_instance_profile }.to hop("add_role_to_instance_profile")
    end

    it "hops to add_role_to_instance_profile if instance profile already exists" do
      expect(iam_client).to receive(:create_instance_profile).and_raise(Aws::IAM::Errors::EntityAlreadyExists.new(nil, "EntityAlreadyExists"))
      expect { nx.create_instance_profile }.to hop("add_role_to_instance_profile")
    end
  end

  describe "#add_role_to_instance_profile" do
    it "adds role to instance profile" do
      iam_client.stub_responses(:add_role_to_instance_profile, {})
      expect(iam_client).to receive(:add_role_to_instance_profile).with({
        instance_profile_name: "#{vm.name}-instance-profile",
        role_name: vm.name
      }).and_call_original

      expect { nx.add_role_to_instance_profile }.to hop("wait_instance_profile_created")
    end

    it "hops to wait_instance_profile_created if role is already added to instance profile" do
      expect(iam_client).to receive(:add_role_to_instance_profile).and_raise(Aws::IAM::Errors::EntityAlreadyExists.new(nil, "LimitExceeded"))
      expect { nx.add_role_to_instance_profile }.to hop("wait_instance_profile_created")
    end
  end

  describe "#wait_instance_profile_created" do
    it "waits for instance profile to be created" do
      iam_client.stub_responses(:get_instance_profile, instance_profile: {instance_profile_name: "#{vm.name}-instance-profile", instance_profile_id: "#{vm.name}-instance-profile-id", path: "/", roles: [], arn: "arn:aws:iam::#{vm.project_id}:instance-profile/#{vm.name}-instance-profile", create_date: Time.now})
      expect(iam_client).to receive(:get_instance_profile).with({
        instance_profile_name: "#{vm.name}-instance-profile"
      }).and_call_original

      expect { nx.wait_instance_profile_created }.to hop("create_instance")
    end

    it "naps if instance profile is not created" do
      expect(iam_client).to receive(:get_instance_profile).and_raise(Aws::IAM::Errors::NoSuchEntity.new(nil, "NoSuchEntity"))
      expect { nx.wait_instance_profile_created }.to nap(1)
    end
  end

  describe "#create_instance" do
    before do
      nic_aws_resource
      client.stub_responses(:describe_subnets, subnets: [{availability_zone_id: "use1-az1"}])
    end

    it "creates an instance" do
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
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
              volume_size: 30,
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
        tag_specifications: Util.aws_tag_specifications("instance", vm.name),
        iam_instance_profile: {name: "#{vm.name}-instance-profile"},
        client_token: vm.id,
        instance_market_options: nil,
        user_data: Base64.encode64(user_data)
      }).and_call_original
      expect { nx.create_instance }.to hop("wait_instance_created")
      expect(vm.aws_instance).to have_attributes(instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
    end

    it "skips instance profile creation for runner instances" do
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      vm.update(unix_user: "runneradmin")
      expect(client).to receive(:run_instances).with(hash_not_including(:iam_instance_profile)).and_call_original
      expect { nx.create_instance }.to hop("wait_instance_created")
      expect(vm.aws_instance).to have_attributes(instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
    end

    it "naps until instance profile not propagated yet" do
      client.stub_responses(:run_instances, Aws::EC2::Errors::InvalidParameterValue.new(nil, "Invalid IAM Instance Profile name"))
      expect { nx.create_instance }
        .to nap(1)
        .and change(client, :api_requests)
        .to(include(a_hash_including(operation_name: :run_instances)))
    end

    it "raises exception if it's not for invalid instance profile" do
      client.stub_responses(:run_instances, Aws::EC2::Errors::InvalidParameterValue.new(nil, "Invalid instance name"))
      expect { nx.create_instance }.to raise_error(Aws::EC2::Errors::InvalidParameterValue)
    end

    it "sets transparent cache host for runners" do
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      vm.update(unix_user: "runneradmin")
      expected_user_data = user_data + "echo \"#{vm.private_ipv4} ubicloudhostplaceholder.blob.core.windows.net\" >> /etc/hosts"
      expect(client).to receive(:run_instances).with(hash_including(
        user_data: Base64.encode64(expected_user_data)
      )).and_call_original
      expect { nx.create_instance }.to hop("wait_instance_created")
      expect(vm.aws_instance).to have_attributes(instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
    end

    it "uses spot instances for runners when enabled" do
      expect(Config).to receive(:github_runner_aws_spot_instance_enabled).and_return(true)
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      vm.update(unix_user: "runneradmin")
      expect(client).to receive(:run_instances).with(hash_including(
        instance_market_options: {market_type: "spot", spot_options: {instance_interruption_behavior: "terminate", spot_instance_type: "one-time"}}
      )).and_call_original
      expect { nx.create_instance }.to hop("wait_instance_created")
      expect(vm.aws_instance).to have_attributes(instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
    end

    it "sets max price for spot instances if provided" do
      expect(Config).to receive(:github_runner_aws_spot_instance_enabled).and_return(true)
      expect(Config).to receive(:github_runner_aws_spot_instance_max_price_per_vcpu).and_return(0.001).at_least(:once)
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      vm.update(unix_user: "runneradmin")
      expect(client).to receive(:run_instances).with(hash_including(
        instance_market_options: {market_type: "spot", spot_options: {instance_interruption_behavior: "terminate", spot_instance_type: "one-time", max_price: "0.12"}}
      )).and_call_original
      expect { nx.create_instance }.to hop("wait_instance_created")
      expect(vm.aws_instance).to have_attributes(instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
    end

    describe "when insufficient capacity error" do
      def set_alternative_families(families)
        refresh_frame(nx, new_values: {"alternative_families" => families})
      end

      before do
        client.stub_responses(:run_instances, Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "Insufficient capacity for instance type"))
        vm.update(unix_user: "runneradmin")
        installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: vm.project_id)
        GithubRunner.create(label: "ubicloud-standard-2", repository_name: "ubicloud/test", installation_id: installation.id, vm_id: vm.id)
        expect(Clog).to receive(:emit).with("insufficient instance capacity", instance_of(Hash)).and_call_original
      end

      it "recreates runner when alternative_families is nil" do
        set_alternative_families(nil)
        expect { nx.create_instance }.to nap(60).and change(GithubRunner, :count).by(1)
      end

      it "recreates runner when alternative_families is empty" do
        set_alternative_families([])
        expect { nx.create_instance }.to nap(60).and change(GithubRunner, :count).by(1)
      end

      it "creates runner with the first alternative when current_family is the initial family" do
        set_alternative_families(["m7i", "m6a"])
        expect { nx.create_instance }.to nap(0)
          .and not_change(GithubRunner, :count)
          .and change { vm.reload.family }.from("m6gd").to("m7i")
      end

      it "creates runner with the next alternative when current_family is the first family" do
        vm.update(family: "m7i")
        set_alternative_families(["m7i", "m6a"])
        expect { nx.create_instance }.to nap(0)
          .and not_change(GithubRunner, :count)
          .and change { vm.reload.family }.from("m7i").to("m6a")
      end

      it "recreates runner when current_family is the last family" do
        vm.update(family: "m6a")
        set_alternative_families(["m7i", "m6a"])
        expect { nx.create_instance }.to nap(60).and change(GithubRunner, :count).by(1)
      end
    end

    describe "when insufficient capacity error for non-runner" do
      let(:nic) { vm.nics.first }
      let(:nic_nx) { Prog::Vnet::Aws::NicNexus.new(nic.strand) }

      before do
        client.stub_responses(:run_instances, Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "Insufficient capacity"))
        nic.nic_aws_resource.update(subnet_az: "a")
        refresh_frame(nic_nx, new_frame: {"exclude_availability_zones" => []})
      end

      it "retries by excluding the failed AZ on first failure" do
        expect(Clog).to receive(:emit).with("retrying in different az", instance_of(Hash)).and_call_original
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
          .and change { nic.reload.destroy_set? }.from(false).to(true)
        expect(st.stack.last["exclude_availability_zones"]).to eq(["a"])
        expect(st.stack.last["retry_count"]).to eq(1)
      end

      it "increments retry count on subsequent failures" do
        refresh_frame(nx, new_values: {"retry_count" => 2})
        refresh_frame(nic_nx, new_values: {"exclude_availability_zones" => ["b", "c"]})
        expect(Clog).to receive(:emit).with("retrying in different az", instance_of(Hash)).and_call_original
        expect(nx).to receive(:update_stack).with({
          "exclude_availability_zones" => ["b", "c", "a"],
          "retry_count" => 3
        }).and_call_original
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
      end

      it "avoids duplicate AZs in exclusion list" do
        refresh_frame(nic_nx, new_values: {"exclude_availability_zones" => ["a", "b"]})
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
        expect(st.stack.last["exclude_availability_zones"]).to eq(["a", "b"])
      end

      it "clear exclude_availability_zones after 5 retry attempts" do
        refresh_frame(nx, new_values: {"retry_count" => 5})
        expect(Clog).not_to receive(:emit).with("retrying in different az", instance_of(Hash))
        expect { nx.create_instance }.to nap(300)
        expect(st.stack.last["exclude_availability_zones"]).to be_nil
      end

      it "logs retry details in emission" do
        refresh_frame(nx, new_values: {"retry_count" => 3})
        expect(Clog).to receive(:emit).with("retrying in different az", instance_of(Hash)).and_wrap_original do |m, a, b|
          expect(b).to eq(retry_different_az: {
            vm:,
            error: "Aws::EC2::Errors::InsufficientInstanceCapacity",
            message: "Insufficient capacity",
            retry_count: 4
          })
        end
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
      end
    end

    describe "when unsupported instance type error" do
      let(:nic) { vm.nics.first }
      let(:nic_nx) { Prog::Vnet::Aws::NicNexus.new(nic.strand) }

      before do
        client.stub_responses(:run_instances, Aws::EC2::Errors::Unsupported.new(nil, "Instance type not supported"))
        nic.nic_aws_resource.update(subnet_az: "a")
        refresh_frame(nic_nx, new_frame: {"exclude_availability_zones" => []})
      end

      it "retries by excluding the failed AZ on first failure" do
        expect(Clog).to receive(:emit).with("retrying in different az", instance_of(Hash)).and_call_original
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
          .and change { nic.reload.destroy_set? }.from(false).to(true)
        expect(st.stack.last["exclude_availability_zones"]).to eq(["a"])
        expect(st.stack.last["retry_count"]).to eq(1)
      end

      it "increments retry count on subsequent failures" do
        refresh_frame(nx, new_values: {"retry_count" => 2})
        refresh_frame(nic_nx, new_values: {"exclude_availability_zones" => ["b", "c"]})
        expect(Clog).to receive(:emit).with("retrying in different az", instance_of(Hash)).and_call_original
        expect(nx).to receive(:update_stack).with({
          "exclude_availability_zones" => ["b", "c", "a"],
          "retry_count" => 3
        }).and_call_original
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
      end

      it "avoids duplicate AZs in exclusion list" do
        refresh_frame(nic_nx, new_values: {"exclude_availability_zones" => ["a", "b"]})
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
        expect(st.stack.last["exclude_availability_zones"]).to eq(["a", "b"])
      end

      it "clear exclude_availability_zones after 5 retry attempts" do
        refresh_frame(nx, new_values: {"retry_count" => 5})
        expect(Clog).not_to receive(:emit).with("retrying in different az", instance_of(Hash))
        expect { nx.create_instance }.to nap(300)
        expect(st.stack.last["exclude_availability_zones"]).to be_nil
      end

      it "logs retry details in emission" do
        refresh_frame(nx, new_values: {"retry_count" => 3})
        expect(Clog).to receive(:emit).with("retrying in different az", instance_of(Hash)).and_wrap_original do |m, a, b|
          expect(b).to eq(retry_different_az: {
            vm:,
            error: "Aws::EC2::Errors::Unsupported",
            message: "Instance type not supported",
            retry_count: 4
          })
        end
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
      end
    end
  end

  describe "#wait_instance_created" do
    before do
      aws_instance
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "running"}, network_interfaces: [{association: {public_ip: "1.2.3.4"}, ipv_6_addresses: [{ipv_6_address: "2a01:4f8:173:1ed3:aa7c::/79"}]}]}]}])
    end

    it "updates the vm" do
      now = Time.now.floor
      expect(Time).to receive(:now).at_least(:once).and_return(now)
      expect { nx.wait_instance_created }.to hop("wait_sshable")
      vm.reload
      expect(vm.cores).to eq(1)
      expect(vm.ephemeral_net6.to_s).to eq("2a01:4f8:173:1ed3:aa7c::/79")
      expect(vm.allocated_at).to eq(now)
    end

    it "updates the sshable host" do
      expect { nx.wait_instance_created }.to hop("wait_sshable")
        .and change { vm.sshable.reload.host }.to("1.2.3.4")
    end

    it "naps if the instance is not running" do
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "pending"}}]}])
      expect { nx.wait_instance_created }
        .to nap(1)
        .and change(client, :api_requests)
        .to(include(a_hash_including(
          operation_name: :describe_instances,
          params: a_hash_including(filters: [
            {name: "instance-id", values: ["i-0123456789abcdefg"]},
            {name: "tag:Ubicloud", values: ["true"]}
          ])
        )))
    end

    it "naps if the reservations response is empty" do
      client.stub_responses(:describe_instances, reservations: [])
      expect { nx.wait_instance_created }.to nap(1)
    end
  end

  describe "#wait_instance_created", "without sshable" do
    let(:vm) { vm_without_sshable }
    let(:aws_instance) { AwsInstance.create_with_id(vm, instance_id: "i-0123456789abcdefg") }

    before do
      aws_instance
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "running"}, network_interfaces: [{association: {public_ip: "1.2.3.4"}, ipv_6_addresses: [{ipv_6_address: "2a01:4f8:173:1ed3:aa7c::/79"}]}]}]}])
    end

    it "handles vm without sshable" do
      expect { nx.wait_instance_created }
        .to hop("wait_sshable")
        .and change(client, :api_requests)
        .to(include(a_hash_including(
          operation_name: :describe_instances,
          params: a_hash_including(filters: [
            {name: "instance-id", values: ["i-0123456789abcdefg"]},
            {name: "tag:Ubicloud", values: ["true"]}
          ])
        )))
        .and change { vm.reload.cores }.to(1)
    end
  end

  describe "#wait_old_nic_deleted" do
    let(:old_nic) { vm.nics.first }
    let(:private_subnet_id) { old_nic.private_subnet_id }

    before do
      refresh_frame(nx, new_values: {"private_subnet_id" => private_subnet_id, "exclude_availability_zones" => ["a", "b"]})
    end

    it "naps if old NIC still exists" do
      expect(vm.nic).to exist
      expect { nx.wait_old_nic_deleted }.to nap(1)
    end

    it "creates new NIC and hops to wait_nic_recreated when old NIC is deleted" do
      old_nic.update(vm_id: nil)
      vm.reload

      expect { nx.wait_old_nic_deleted }.to hop("wait_nic_recreated")
      expect(vm.reload.nic.id).not_to eq(old_nic.id)
      expect(vm.nic.strand.label).to eq("start")
      expect(vm.nic.strand.stack.first["exclude_availability_zones"]).to eq(["a", "b"])
    end
  end

  describe "#wait_nic_recreated" do
    let(:nic) { vm.nics.first }

    it "naps if NIC strand is not in wait state" do
      nic.strand.update(label: "start")
      expect { nx.wait_nic_recreated }.to nap(1)
    end

    it "hops to create_instance when NIC strand is in wait state" do
      nic.strand.update(label: "wait")
      expect { nx.wait_nic_recreated }.to hop("create_instance")
    end
  end

  describe "#wait_sshable" do
    it "naps 6 seconds if it's the first time we execute wait_sshable" do
      expect { nx.wait_sshable }.to nap(6)
        .and change { vm.reload.update_firewall_rules_set? }.from(false).to(true)
    end

    it "naps if not sshable" do
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "10.0.0.1/32")
      vm.incr_update_firewall_rules
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1).and_raise Errno::ECONNREFUSED
      expect { nx.wait_sshable }.to nap(1)
    end

    it "hops to create_billing_record if sshable" do
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "10.0.0.1/32")
      vm.incr_update_firewall_rules
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1)
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end

    it "skips a check if ipv4 is not enabled" do
      vm.incr_update_firewall_rules
      expect(vm.ip4).to be_nil
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end
  end

  describe "#create_billing_record" do
    let(:now) { Time.now }

    before do
      aws_instance
      expect(Time).to receive(:now).and_return(now).at_least(:once)
      vm.update(allocated_at: now - 100)
      expect(Clog).to receive(:emit).with("vm provisioned", instance_of(Array)).and_call_original
    end

    it "not create billing records when the project is not billable" do
      vm.project.update(billable: false)
      expect { nx.create_billing_record }.to hop("wait")
      expect(BillingRecord.all).to be_empty
    end

    it "creates billing records for only vm" do
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
    it "hops to wait_firewall_rules" do
      nx.incr_update_firewall_rules
      expect(nx).to receive(:push).with(Prog::Vnet::Aws::UpdateFirewallRules, {}, :update_firewall_rules)
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

    it "exits directly if it's a runner" do
      vm.update(unix_user: "runneradmin")
      expect { nx.destroy }.to exit({"msg" => "vm destroyed"})
    end

    it "hops to cleanup_roles if there is no aws_instance" do
      expect { nx.destroy }.to hop("cleanup_roles")
    end
  end

  describe "#destroy", "with aws_instance" do
    it "deletes the instance" do
      aws_instance
      expect(client).to receive(:terminate_instances).with({instance_ids: ["i-0123456789abcdefg"]})
      expect { nx.destroy }.to hop("cleanup_roles")
      expect(aws_instance).not_to exist
    end
  end

  describe "#cloudwatch_policy" do
    it "finds policy on first page" do
      iam_client.stub_responses(:list_policies, policies: [{policy_name: "#{vm.name}-cw-agent-policy", arn: "arn:aws:iam::aws:policy/#{vm.name}-cw-agent-policy"}], is_truncated: false)
      policy = nx.cloudwatch_policy
      expect(policy).not_to be_nil
      expect(policy.policy_name).to eq("#{vm.name}-cw-agent-policy")
    end

    it "paginates through multiple pages to find policy" do
      # First page: no match, has more pages
      first_response = iam_client.stub_data(:list_policies, {
        policies: [{policy_name: "other-policy-1", arn: "arn:aws:iam::aws:policy/other-policy-1"}],
        is_truncated: true,
        marker: "next-page-marker"
      })

      # Second page: has the policy we're looking for
      second_response = iam_client.stub_data(:list_policies, {
        policies: [{policy_name: "#{vm.name}-cw-agent-policy", arn: "arn:aws:iam::aws:policy/#{vm.name}-cw-agent-policy"}],
        is_truncated: false
      })

      iam_client.stub_responses(:list_policies, first_response, second_response)

      policy = nx.cloudwatch_policy
      expect(policy).not_to be_nil
      expect(policy.policy_name).to eq("#{vm.name}-cw-agent-policy")
    end

    it "returns nil when policy not found after all pages" do
      # First page: no match, has more pages
      first_response = iam_client.stub_data(:list_policies, {
        policies: [{policy_name: "other-policy-1", arn: "arn:aws:iam::aws:policy/other-policy-1"}],
        is_truncated: true,
        marker: "next-page-marker"
      })

      # Second page: no match, last page
      second_response = iam_client.stub_data(:list_policies, {
        policies: [{policy_name: "other-policy-2", arn: "arn:aws:iam::aws:policy/other-policy-2"}],
        is_truncated: false
      })

      iam_client.stub_responses(:list_policies, first_response, second_response)

      policy = nx.cloudwatch_policy
      expect(policy).to be_nil
      expect(iam_client.api_requests).to include(
        a_hash_including(operation_name: :list_policies, params: a_hash_including(scope: "Local", max_items: 100, marker: nil)),
        a_hash_including(operation_name: :list_policies, params: a_hash_including(scope: "Local", max_items: 100, marker: "next-page-marker"))
      )
    end
  end

  describe "#aws_ami_id" do
    it "returns boot_image directly if it starts with ami-" do
      vm.update(boot_image: "ami-030c060f85668b37d")
      expect(nx.aws_ami_id).to eq("ami-030c060f85668b37d")
    end

    it "looks up AMI by boot image name for ubuntu-noble arm64" do
      vm.update(boot_image: "ubuntu-noble", arch: "arm64")
      client.stub_responses(:describe_images, images: [
        {image_id: "ami-111111111", creation_date: "2024-01-01T00:00:00Z"},
        {image_id: "ami-222222222", creation_date: "2024-06-01T00:00:00Z"}
      ])
      expect(nx.aws_ami_id).to eq("ami-222222222")
    end

    it "looks up AMI by boot image name for ubuntu-noble x64" do
      vm.update(boot_image: "ubuntu-noble", arch: "x64")
      client.stub_responses(:describe_images, images: [
        {image_id: "ami-333333333", creation_date: "2024-01-01T00:00:00Z"}
      ])
      expect(client).to receive(:describe_images).with(
        filters: [
          {name: "name", values: ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]},
          {name: "owner-id", values: ["099720109477"]},
          {name: "state", values: ["available"]}
        ]
      ).and_call_original
      expect(nx.aws_ami_id).to eq("ami-333333333")
    end

    it "raises if boot image is unknown" do
      vm.update(boot_image: "unknown-image")
      expect { nx.aws_ami_id }.to raise_error(RuntimeError, /Unknown boot image/)
    end

    it "raises if no AMI found" do
      vm.update(boot_image: "ubuntu-noble", arch: "arm64")
      client.stub_responses(:describe_images, images: [])
      expect { nx.aws_ami_id }.to raise_error(RuntimeError, /No AMI found/)
    end
  end

  describe "#cleanup_roles" do
    it "cleans up roles" do
      allow(Config).to receive(:aws_postgres_iam_access).and_return(true)
      iam_client.stub_responses(:list_policies, policies: [{policy_name: "#{vm.name}-cw-agent-policy", arn: "arn:aws:iam::aws:policy/#{vm.name}-cw-agent-policy"}])
      iam_client.stub_responses(:remove_role_from_instance_profile, {})
      iam_client.stub_responses(:delete_instance_profile, {})
      iam_client.stub_responses(:delete_policy, {})
      iam_client.stub_responses(:delete_role, {})
      policies = iam_client.stub_data(:list_attached_role_policies, {attached_policies: [
        {policy_name: "policy-name", policy_arn: "policy-arn"}
      ]})
      iam_client.stub_responses(:list_attached_role_policies, policies)
      iam_client.stub_responses(:detach_role_policy, {})
      expect(iam_client).to receive(:detach_role_policy).with({policy_arn: "arn:aws:iam::aws:policy/testvm-cw-agent-policy", role_name: "testvm"}).and_call_original
      expect(iam_client).to receive(:detach_role_policy).with({role_name: vm.name, policy_arn: "policy-arn"}).and_call_original

      expect { nx.cleanup_roles }
        .to exit({"msg" => "vm destroyed"})
        .and change(iam_client, :api_requests)
        .to(include(
          a_hash_including(operation_name: :remove_role_from_instance_profile, params: {instance_profile_name: "testvm-instance-profile", role_name: "testvm"}),
          a_hash_including(operation_name: :delete_instance_profile, params: {instance_profile_name: "testvm-instance-profile"}),
          a_hash_including(operation_name: :delete_policy, params: {policy_arn: "arn:aws:iam::aws:policy/testvm-cw-agent-policy"}),
          a_hash_including(operation_name: :delete_role, params: {role_name: "testvm"})
        ))
    end

    it "skips policy cleanup if the cloudwatch policy doesn't exist" do
      iam_client.stub_responses(:list_policies, policies: [])
      iam_client.stub_responses(:remove_role_from_instance_profile, {})
      iam_client.stub_responses(:delete_instance_profile, {})
      iam_client.stub_responses(:delete_role, {})
      expect { nx.cleanup_roles }
        .to exit({"msg" => "vm destroyed"})
        .and change(iam_client, :api_requests)
        .to(include(
          a_hash_including(operation_name: :remove_role_from_instance_profile, params: {instance_profile_name: "testvm-instance-profile", role_name: "testvm"}),
          a_hash_including(operation_name: :delete_instance_profile, params: {instance_profile_name: "testvm-instance-profile"}),
          a_hash_including(operation_name: :delete_role, params: {role_name: "testvm"})
        ))
    end
  end
end
