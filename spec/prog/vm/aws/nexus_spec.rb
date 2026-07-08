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

  let(:location_credential_aws) {
    loc = LocationCredentialAws.create_with_id(location, access_key: "test-access-key", secret_key: "test-secret-key")
    LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
    LocationAz.create(location_id: loc.id, az: "b", zone_id: "usw2-az2")
    LocationAz.create(location_id: loc.id, az: "c", zone_id: "usw2-az3")
    LocationAz.create(location_id: loc.id, az: "d", zone_id: "usw2-az4")
    LocationAz.create(location_id: loc.id, az: "e", zone_id: "usw2-az5")
    LocationAz.create(location_id: loc.id, az: "f", zone_id: "usw2-az6")
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
    location_credential_aws  # force creation
    Prog::Vm::Nexus.assemble_with_sshable(project.id, **vm_params).subject
  }

  let(:vm_without_sshable) {
    location_credential_aws
    Prog::Vm::Nexus.assemble("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI", project.id, **vm_params).subject
  }

  let(:aws_instance) { AwsInstance.create_with_id(vm, instance_id: "i-0123456789abcdefg") }

  let(:nic_aws_resource) {
    NicAwsResource.create_with_id(vm.user_nic, network_interface_id: "eni-0123456789abcdefg", subnet_id: "subnet-12345678")
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
      LocationCredentialAws.create_with_id(loc.id, access_key: "test-access-key", secret_key: "test-secret-key")
      LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
      loc
    }

    it "creates one VmStorageVolume per input storage volume on AWS" do
      storage_volumes = [
        {encrypted: true, size_gib: 30},
        {encrypted: true, size_gib: 7500},
      ]

      vm = Prog::Vm::Nexus.assemble("some_ssh key", project.id, location_id: assemble_loc.id, size: "i8g.8xlarge", arch: "arm64", storage_volumes:).subject
      expect(vm.vm_storage_volumes.count).to eq(2)
      expect(vm.vm_storage_volumes.map(&:size_gib).sort).to eq([30, 7500])
    end

    it "hops to start_aws if location is aws" do
      st = Prog::Vm::Nexus.assemble("some_ssh key", project.id, location_id: assemble_loc.id)
      expect(st.label).to eq("start")
    end

    it "fails if machine image is provided for non-metal location" do
      expect {
        Prog::Vm::Nexus.assemble("some_ssh key", project.id, location_id: assemble_loc.id, boot_image: "test-image@1.0")
      }.to raise_error("Machine images are only supported for metal locations")
    end

    it "creates a management NIC when use_separate_management_nic is set" do
      vm = Prog::Vm::Nexus.assemble("some_ssh key", project.id, location_id: assemble_loc.id, use_separate_management_nic: true).subject
      expect(vm.nics.count).to eq(2)
      expect(vm.user_nic).not_to be_nil
      expect(vm.management_nic).not_to be_nil
    end
  end

  describe "#before_destroy" do
    it "finalizes active billing records" do
      br = BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: vm.name,
        billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
        amount: vm.vcpus,
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
      vm.user_nic.strand.update(label: "start")
      expect { nx.start }.to nap(1)
    end

    it "creates a role for instance" do
      vm.user_nic.strand.update(label: "wait")
      iam_client.stub_responses(:create_role, {role: {role_name: vm.name, path: "/", role_id: "ROLE123", arn: "arn:aws:iam::123456789012:role/#{vm.name}", create_date: Time.now}})
      expect(iam_client).to receive(:create_role).with({
        role_name: vm.name,
        assume_role_policy_document: {
          Version: "2012-10-17",
          Statement: [
            {
              Effect: "Allow",
              Principal: {Service: "ec2.amazonaws.com"},
              Action: "sts:AssumeRole",
            },
          ],
        }.to_json,
        tags: Util.aws_tags(vm.name),
      }).and_call_original

      expect { nx.start }.to hop("create_role_policy")
    end

    it "hops to create_role_policy if role already exists" do
      vm.user_nic.strand.update(label: "wait")
      expect(iam_client).to receive(:create_role).with({role_name: vm.name, assume_role_policy_document: {
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Principal: {Service: "ec2.amazonaws.com"},
            Action: "sts:AssumeRole",
          },
        ],
      }.to_json, tags: Util.aws_tags(vm.name)}).and_raise(Aws::IAM::Errors::EntityAlreadyExists.new(nil, "EntityAlreadyExists"))
      expect { nx.start }.to hop("create_role_policy")
    end

    it "hops to create_instance if it's a runner instance" do
      vm.user_nic.strand.update(label: "wait")
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
                "logs:CreateLogGroup",
              ],
              Resource: [
                "arn:aws:logs:*:*:log-group:/#{vm.name}/auth:log-stream:*",
                "arn:aws:logs:*:*:log-group:/#{vm.name}/postgresql:log-stream:*",
              ],
            },
            {
              Effect: "Allow",
              Action: "logs:DescribeLogStreams",
              Resource: [
                "arn:aws:logs:*:*:log-group:/#{vm.name}/auth:*",
                "arn:aws:logs:*:*:log-group:/#{vm.name}/postgresql:*",
              ],
            },
            {
              Effect: "Allow",
              Action: "guardduty:SendSecurityTelemetry",
              Resource: "*",
            },
          ],
        }.to_json,
        tags: Util.aws_tags("#{vm.name}-cw-agent-policy"),
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
        policy_arn: "arn:aws:iam::aws:policy/#{vm.name}-cw-agent-policy",
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
        instance_profile_name: "#{vm.name}-instance-profile",
        tags: Util.aws_tags("#{vm.name}-instance-profile"),
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
        role_name: vm.name,
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
        instance_profile_name: "#{vm.name}-instance-profile",
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
              throughput: 125,
            },
          },
        ],
        network_interfaces: [
          {
            network_interface_id: "eni-0123456789abcdefg",
            device_index: 0,
          },
        ],
        private_dns_name_options: {
          hostname_type: "ip-name",
          enable_resource_name_dns_a_record: false,
          enable_resource_name_dns_aaaa_record: false,
        },
        metadata_options: {http_tokens: "required"},
        min_count: 1,
        max_count: 1,
        tag_specifications: Util.aws_tag_specifications("instance", vm.name) + Util.aws_tag_specifications("volume", vm.name),
        iam_instance_profile: {name: "#{vm.name}-instance-profile"},
        client_token: vm.id,
        instance_market_options: nil,
        user_data: Base64.encode64(user_data),
      }).and_call_original
      expect { nx.create_instance }.to hop("wait_instance_created")
      expect(vm.aws_instance).to have_attributes(instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
    end

    it "attaches both pre-created mgmt and user ENIs and policy-routes the data NIC" do
      user_nic_record = vm.user_nic
      aws_subnet = user_nic_record.private_subnet.private_subnet_aws_resource.aws_subnets.first
      nic_aws_resource.update(subnet_id: "subnet-12345678", aws_subnet_id: aws_subnet.id)
      mgmt_nic = Prog::Vnet::NicNexus.assemble(user_nic_record.private_subnet_id, name: "#{vm.name}-mgmt-nic", is_management: true).subject
      mgmt_nic.update(vm_id: vm.id)
      NicAwsResource.create_with_id(mgmt_nic.id, network_interface_id: "eni-mgmt-0000000000", subnet_id: "subnet-12345678")
      refresh_frame(nx, new_values: {"use_separate_management_nic" => true})
      client.stub_responses(:describe_network_interfaces, network_interfaces: [
        {network_interface_id: "eni-mgmt-0000000000", mac_address: "0a:00:00:00:00:01", private_ip_address: "10.0.1.4"},
        {network_interface_id: "eni-0123456789abcdefg", mac_address: "0a:1b:2c:3d:4e:5f", private_ip_address: "10.0.1.5"},
      ])
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      expect(client).to receive(:run_instances).with(hash_including(
        network_interfaces: [
          {network_interface_id: "eni-mgmt-0000000000", device_index: 0},
          {network_interface_id: "eni-0123456789abcdefg", device_index: 1},
        ],
      )).and_call_original
      expect { nx.create_instance }.to hop("wait_instance_created")
      user_data = Base64.decode64(client.api_requests.find { it[:operation_name] == :run_instances }[:params][:user_data])
      # mgmt NIC: only SSH (from-mgmt) on table 100, default suppressed; data NIC: main default + table 200
      expect(user_data).to include('macaddress: "0a:00:00:00:00:01"').and include('macaddress: "0a:1b:2c:3d:4e:5f"')
      expect(user_data).to include("use-routes: false").and include("network: {config: disabled}")
      expect(user_data).to include("{from: 10.0.1.4/32, table: 100}").and include("{from: 10.0.1.5/32, table: 200}")
    end

    it "routes GuardDuty telemetry out the mgmt NIC when the endpoint is present" do
      vm.project.set_ff_aws_cloudwatch_logs(true)
      aws_subnet = vm.user_nic.private_subnet.private_subnet_aws_resource.aws_subnets.first
      vm.user_nic.private_subnet.private_subnet_aws_resource.update(vpc_id: "vpc-12345678")
      nic_aws_resource.update(subnet_id: "subnet-12345678", aws_subnet_id: aws_subnet.id)
      mgmt_nic = Prog::Vnet::NicNexus.assemble(vm.user_nic.private_subnet_id, name: "#{vm.name}-mgmt-nic", is_management: true).subject
      mgmt_nic.update(vm_id: vm.id)
      NicAwsResource.create_with_id(mgmt_nic.id, network_interface_id: "eni-mgmt-0000000000", subnet_id: "subnet-12345678")
      refresh_frame(nx, new_values: {"use_separate_management_nic" => true})
      client.stub_responses(:describe_network_interfaces,
        {network_interfaces: [
          {network_interface_id: "eni-mgmt-0000000000", mac_address: "0a:00:00:00:00:01", private_ip_address: "10.0.1.4"},
          {network_interface_id: "eni-0123456789abcdefg", mac_address: "0a:1b:2c:3d:4e:5f", private_ip_address: "10.0.1.5"},
        ]},
        {network_interfaces: [{network_interface_id: "eni-gd-0000000000", private_ip_address: "10.0.1.9"}]})
      client.stub_responses(:describe_vpc_endpoints, vpc_endpoints: [{vpc_endpoint_id: "vpce-1", network_interface_ids: ["eni-gd-0000000000"]}])
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      expect { nx.create_instance }.to hop("wait_instance_created")
      user_data = Base64.decode64(client.api_requests.find { it[:operation_name] == :run_instances }[:params][:user_data])
      expect(user_data).to include("routing-policy: [{from: 10.0.1.4/32, table: 100}, {to: 10.0.1.9/32, table: 100}]")
    end

    it "skips instance profile creation for runner instances" do
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      vm.update(unix_user: "runneradmin")
      expect(client).to receive(:run_instances).with(hash_not_including(:iam_instance_profile)).and_call_original
      expect { nx.create_instance }.to hop("wait_instance_created")
      expect(vm.aws_instance).to have_attributes(instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
    end

    it "uses an AWS-assigned public IP instead of an EIP when the nic does not use an eip" do
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678", network_interface_id: "eni-aws-created"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      vm.update(unix_user: "runneradmin")
      vm.user_nic.nic_aws_resource.update(use_eip: false)
      vm.user_nic.private_subnet.private_subnet_aws_resource.update(user_security_group_id: "sg-12345678")
      expect(client).to receive(:run_instances).with(hash_including(
        network_interfaces: [
          {
            device_index: 0,
            subnet_id: "subnet-12345678",
            private_ip_address: vm.user_nic.private_ipv4.network.to_s,
            groups: ["sg-12345678"],
            associate_public_ip_address: true,
            ipv_6_address_count: 1,
            delete_on_termination: true,
          },
        ],
      )).and_call_original
      expect { nx.create_instance }.to hop("wait_instance_created")
      # The launch-created interface id is recorded so later labels can look it up.
      expect(vm.user_nic.nic_aws_resource.reload.network_interface_id).to eq("eni-aws-created")
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
        user_data: Base64.encode64(expected_user_data),
      )).and_call_original
      expect { nx.create_instance }.to hop("wait_instance_created")
      expect(vm.aws_instance).to have_attributes(instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
    end

    it "uses spot instances for runners when enabled" do
      expect(Config).to receive(:github_runner_aws_spot_instance_enabled).and_return(true)
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      vm.update(unix_user: "runneradmin")
      expect(client).to receive(:run_instances).with(hash_including(
        instance_market_options: {market_type: "spot", spot_options: {instance_interruption_behavior: "terminate", spot_instance_type: "one-time"}},
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
        instance_market_options: {market_type: "spot", spot_options: {instance_interruption_behavior: "terminate", spot_instance_type: "one-time", max_price: "0.12"}},
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
      let(:nic) { vm.user_nic }

      before do
        client.stub_responses(:run_instances, Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "Insufficient capacity"))
        nic.nic_aws_resource.update(subnet_az: "a")
      end

      it "adds failed AZ to exclude_availability_zones on first failure" do
        expect(Clog).to receive(:emit).with("retrying in different az", instance_of(Hash)).and_call_original
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
          .and change { nic.reload.destroy_set? }.from(false).to(true)
        expect(st.stack.last["exclude_availability_zones"]).to eq(["a"])
        expect(st.stack.last["unsupported_azs"]).to eq([])
      end

      it "preserves unsupported_azs from use_different_az" do
        refresh_frame(nx, new_values: {"unsupported_azs" => ["b"]})
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
        expect(st.stack.last["unsupported_azs"]).to eq(["b"])
        expect(st.stack.last["exclude_availability_zones"]).to eq(["a"])
      end

      it "resets only exclude_availability_zones when all AZs tried" do
        refresh_frame(nx, new_values: {"unsupported_azs" => ["b", "c", "d"], "exclude_availability_zones" => ["e", "f"]})
        expect(Clog).to receive(:emit).with("resetting transient az exclusions", instance_of(Hash))
        expect { nx.create_instance }.to nap(300)
        expect(st.stack.last["unsupported_azs"]).to eq(["b", "c", "d"])
        expect(st.stack.last["exclude_availability_zones"]).to eq([])
      end

      it "avoids duplicate AZs in exclude_availability_zones" do
        refresh_frame(nx, new_values: {"exclude_availability_zones" => ["a", "b"]})
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
        expect(st.stack.last["exclude_availability_zones"]).to eq(["a", "b"])
      end
    end

    describe "when unsupported instance type error" do
      let(:nic) { vm.user_nic }

      before do
        client.stub_responses(:run_instances, Aws::EC2::Errors::Unsupported.new(nil, "Instance type not supported"))
        nic.nic_aws_resource.update(subnet_az: "a")
      end

      it "adds failed AZ to unsupported_azs on first failure" do
        expect(Clog).to receive(:emit).with("retrying in different az", instance_of(Hash)).and_call_original
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
          .and change { nic.reload.destroy_set? }.from(false).to(true)
        expect(st.stack.last["unsupported_azs"]).to eq(["a"])
        expect(st.stack.last["exclude_availability_zones"]).to eq([])
      end

      it "pages and naps 1 hour when all AZs are unsupported" do
        refresh_frame(nx, new_values: {"unsupported_azs" => ["b", "c", "d", "e", "f"]})
        expect(Clog).to receive(:emit).with("all azs unsupported for instance type", instance_of(Hash))
        expect(Prog::PageNexus).to receive(:assemble).with("#{vm.name} instance type unsupported in all AZs", ["InstanceTypeUnsupported", vm.id], vm.ubid)
        expect { nx.create_instance }.to nap(60 * 60)
        expect(st.stack.last["unsupported_azs"]).to eq(["b", "c", "d", "e", "f", "a"])
        expect(st.stack.last["exclude_availability_zones"]).to eq([])
      end

      it "preserves unsupported_azs when resetting transient exclusions" do
        refresh_frame(nx, new_values: {"unsupported_azs" => ["b", "c", "d"], "exclude_availability_zones" => ["e", "f"]})
        expect(Clog).to receive(:emit).with("resetting transient az exclusions", instance_of(Hash))
        expect { nx.create_instance }.to nap(300)
        expect(st.stack.last["unsupported_azs"]).to eq(["b", "c", "d", "a"])
        expect(st.stack.last["exclude_availability_zones"]).to eq([])
      end

      it "retries in different az with remaining AZs" do
        refresh_frame(nx, new_values: {"unsupported_azs" => ["b"]})
        expect(Clog).to receive(:emit).with("retrying in different az", instance_of(Hash)).and_call_original
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
        expect(st.stack.last["unsupported_azs"]).to eq(["b", "a"])
      end

      it "avoids duplicate AZs in unsupported_azs" do
        refresh_frame(nx, new_values: {"unsupported_azs" => ["a", "b"]})
        expect { nx.create_instance }.to hop("wait_old_nic_deleted")
        expect(st.stack.last["unsupported_azs"]).to eq(["a", "b"])
      end
    end

    describe "mixed error sequences" do
      let(:nic) { vm.user_nic }

      before do
        nic.nic_aws_resource.update(subnet_az: "a")
      end

      it "resets transient but keeps permanent when mixed errors exhaust all AZs" do
        refresh_frame(nx, new_values: {"unsupported_azs" => ["b", "c", "d"], "exclude_availability_zones" => ["e", "f"]})
        client.stub_responses(:run_instances, Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "Insufficient capacity"))
        expect(Clog).to receive(:emit).with("resetting transient az exclusions", instance_of(Hash))
        expect { nx.create_instance }.to nap(300)
        expect(st.stack.last["unsupported_azs"]).to eq(["b", "c", "d"])
        expect(st.stack.last["exclude_availability_zones"]).to eq([])
      end

      it "pages when unsupported errors accumulate across all AZs" do
        refresh_frame(nx, new_values: {"unsupported_azs" => ["b", "c", "d", "e", "f"]})
        client.stub_responses(:run_instances, Aws::EC2::Errors::Unsupported.new(nil, "Instance type not supported"))
        expect(Prog::PageNexus).to receive(:assemble)
        expect { nx.create_instance }.to nap(60 * 60)
        expect(st.stack.last["unsupported_azs"]).to eq(["b", "c", "d", "e", "f", "a"])
      end

      it "does not page when unsupported covers some AZs but transient covers the rest" do
        refresh_frame(nx, new_values: {"unsupported_azs" => ["b", "c", "d"], "exclude_availability_zones" => ["e", "f"]})
        client.stub_responses(:run_instances, Aws::EC2::Errors::Unsupported.new(nil, "Instance type not supported"))
        expect(Prog::PageNexus).not_to receive(:assemble)
        expect(Clog).to receive(:emit).with("resetting transient az exclusions", instance_of(Hash))
        expect { nx.create_instance }.to nap(300)
        expect(st.stack.last["unsupported_azs"]).to eq(["b", "c", "d", "a"])
        expect(st.stack.last["exclude_availability_zones"]).to eq([])
      end
    end

    it "raises on invalid az_failure_type" do
      expect { nx.retry_in_different_az(RuntimeError.new("test"), :bogus) }.to raise_error("unexpected az_failure_type: bogus")
    end

    describe "when postgres family fallback engages" do
      let(:nic) { vm.user_nic }

      before do
        nic.nic_aws_resource.update(subnet_az: "a")
        refresh_frame(nx, new_values: {"unsupported_azs" => ["b", "c", "d", "e", "f"]})
        client.stub_responses(:run_instances, Aws::EC2::Errors::Unsupported.new(nil, "Instance type not supported"))
      end

      it "invokes try_postgres_family_fallback, clears both AZ sets, and naps 0" do
        expect(nx).to receive(:try_postgres_family_fallback).and_return(true)
        expect { nx.create_instance }.to nap(0)
        expect(st.stack.last["unsupported_azs"]).to eq([])
        expect(st.stack.last["exclude_availability_zones"]).to eq([])
      end
    end
  end

  describe "#try_postgres_family_fallback" do
    before do
      # Decouple from config/instance_availability.yml
      allow(OptionTreeFilter).to receive(:filter).with(provider: "aws", location: "us-west-2").and_return(
        [
          {family: "m6gd", size: "m6gd.large"},
          {family: "m7gd", size: "m7gd.large"},
          {family: "m8gd", size: "m8gd.large"},
          {family: "r6gd", size: "r6gd.medium"},
          {family: "r7gd", size: "r7gd.medium"},
          {family: "r8gd", size: "r8gd.medium"},
        ],
      )
    end

    it "returns false when there is no postgres_server for the vm" do
      expect(nx.try_postgres_family_fallback).to be false
    end

    it "returns false when the postgres_server is not fallback eligible" do
      ps = instance_double(PostgresServer, fallback_eligible?: false)
      allow(PostgresServer).to receive(:[]).with(vm_id: vm.id).and_return(ps)
      expect(nx.try_postgres_family_fallback).to be false
    end

    it "returns false when no fallback candidate has a matching postgres size option" do
      vm.update(family: "standard")
      ps = instance_double(PostgresServer, fallback_eligible?: true)
      allow(PostgresServer).to receive(:[]).with(vm_id: vm.id).and_return(ps)
      expect(nx.try_postgres_family_fallback).to be false
    end

    it "skips chain entries whose project feature flag is disabled and lands on the next enabled one" do
      # vm starts on m6gd; chain is [m6gd, m7gd, m8gd]. m7gd needs ff_enable_m7gd
      # (off by default), so the fallback skips it and lands on m8gd (unconditional).
      ps = instance_double(PostgresServer, fallback_eligible?: true, resource: instance_double(PostgresResource, project:, flavor: "standard", location:), ignore_instance_size_mismatch_set?: false)
      allow(PostgresServer).to receive(:[]).with(vm_id: vm.id).and_return(ps)
      expect(ps).to receive(:incr_ignore_instance_size_mismatch)
      expect { nx.try_postgres_family_fallback }.to change { vm.reload.family }.from("m6gd").to("m8gd")
    end

    it "picks an earlier chain entry when its feature flag is enabled" do
      project.set_ff_enable_m7gd(true)
      ps = instance_double(PostgresServer, fallback_eligible?: true, resource: instance_double(PostgresResource, project:, flavor: "standard", location:), ignore_instance_size_mismatch_set?: false)
      allow(PostgresServer).to receive(:[]).with(vm_id: vm.id).and_return(ps)
      expect(ps).to receive(:incr_ignore_instance_size_mismatch)
      expect { nx.try_postgres_family_fallback }.to change { vm.reload.family }.from("m6gd").to("m7gd")
    end

    it "does not incr ignore_instance_size_mismatch when already set" do
      ps = instance_double(PostgresServer, fallback_eligible?: true, resource: instance_double(PostgresResource, project:, flavor: "standard", location:), ignore_instance_size_mismatch_set?: true)
      allow(PostgresServer).to receive(:[]).with(vm_id: vm.id).and_return(ps)
      expect(ps).not_to receive(:incr_ignore_instance_size_mismatch)
      nx.try_postgres_family_fallback
    end

    it "returns false when no chain candidate is allowed by the option tree" do
      # r-family chain members all require per-family feature flags; with none
      # enabled the option tree excludes them, so no candidate is allowed.
      vm.update(family: "r6gd")
      ps = instance_double(PostgresServer, fallback_eligible?: true, resource: instance_double(PostgresResource, project:, flavor: "standard", location:), ignore_instance_size_mismatch_set?: false)
      allow(PostgresServer).to receive(:[]).with(vm_id: vm.id).and_return(ps)
      expect(ps).not_to receive(:incr_ignore_instance_size_mismatch)
      expect(nx.try_postgres_family_fallback).to be false
    end
  end

  describe "#wait_instance_created" do
    before do
      aws_instance
      nic_aws_resource
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "running"}, network_interfaces: [{network_interface_id: "eni-0123456789abcdefg", association: {public_ip: "1.2.3.4"}, ipv_6_addresses: [{ipv_6_address: "2a01:4f8:173:1ed3:aa7c::/79"}]}]}]}])
    end

    it "finds the public IP via the captured interface id for a use_eip:false nic" do
      vm.user_nic.nic_aws_resource.update(use_eip: false, network_interface_id: "eni-aws-created")
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "running"},
                                                                              network_interfaces: [{network_interface_id: "eni-aws-created", association: {public_ip: "1.2.3.4"}, ipv_6_addresses: [{ipv_6_address: "2a01:4f8:173:1ed3:aa7c::/79"}]}]}]}])
      expect { nx.wait_instance_created }.to hop("wait_sshable")
        .and change { vm.sshable.reload.host }.to("1.2.3.4")
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
            {name: "tag:Ubicloud", values: ["true"]},
          ]),
        )))
    end

    it "naps if the reservations response is empty" do
      client.stub_responses(:describe_instances, reservations: [])
      expect { nx.wait_instance_created }.to nap(1)
    end

    it "provisions a spare runner and destroys the runner when the instance is terminated due to AWS internal error" do
      vm.update(unix_user: "runneradmin")
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: vm.project_id)
      runner = GithubRunner.create(label: "ubicloud-standard-2", repository_name: "ubicloud/test", installation_id: installation.id, vm_id: vm.id)
      Strand.create_with_id(runner, prog: "Github::GithubRunnerNexus", label: "start")
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "terminated"}, state_reason: {code: "Server.InternalError", message: "Server.InternalError: Internal error on launch"}}]}])
      expect(Clog).to receive(:emit).with("aws internal error on launch", instance_of(Hash)).and_call_original
      expect { nx.wait_instance_created }.to nap(60 * 60)
        .and change(GithubRunner, :count).from(1).to(2)
        .and change { runner.reload.destroy_set? }.from(false).to(true)
    end

    it "does not provision another spare runner if one was already provisioned" do
      vm.update(unix_user: "runneradmin")
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: vm.project_id)
      runner = GithubRunner.create(label: "ubicloud-standard-2", repository_name: "ubicloud/test", installation_id: installation.id, vm_id: vm.id)
      Strand.create_with_id(runner, prog: "Github::GithubRunnerNexus", label: "start")
      runner.incr_spare_runner_provisioned
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "terminated"}, state_reason: {code: "Server.InternalError", message: "Server.InternalError: Internal error on launch"}}]}])
      expect { nx.wait_instance_created }.to nap(60 * 60)
        .and not_change(GithubRunner, :count)
        .and not_change { runner.reload.destroy_set? }
    end

    it "naps without recreating when the instance is terminated due to a non-internal-error reason" do
      vm.update(unix_user: "runneradmin")
      installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: vm.project_id)
      GithubRunner.create(label: "ubicloud-standard-2", repository_name: "ubicloud/test", installation_id: installation.id, vm_id: vm.id)
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "terminated"}, state_reason: {code: "Client.UserInitiatedShutdown", message: "User initiated shutdown"}}]}])
      expect { nx.wait_instance_created }.to nap(1)
        .and not_change(GithubRunner, :count)
    end

    it "naps without recreating when the instance is terminated due to internal error but the vm is not a runner" do
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "terminated"}, state_reason: {code: "Server.InternalError", message: "Server.InternalError: Internal error on launch"}}]}])
      expect { nx.wait_instance_created }.to nap(1)
    end

    it "naps without recreating when the instance is terminated due to internal error but no GithubRunner record exists" do
      vm.update(unix_user: "runneradmin")
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "terminated"}, state_reason: {code: "Server.InternalError", message: "Server.InternalError: Internal error on launch"}}]}])
      expect { nx.wait_instance_created }.to nap(1)
        .and not_change(GithubRunner, :count)
    end

    it "looks up the tracked NIC by id when there are multiple ENIs" do
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "running"}, network_interfaces: [
        {network_interface_id: "eni-placeholder", association: {public_ip: "9.9.9.9"}, ipv_6_addresses: []},
        {network_interface_id: "eni-0123456789abcdefg", association: {public_ip: "1.2.3.4"}, ipv_6_addresses: [{ipv_6_address: "2a01:4f8:173:1ed3:aa7c::/79"}]},
      ]}]}])
      expect { nx.wait_instance_created }.to hop("wait_sshable")
      expect(vm.sshable.reload.host).to eq("1.2.3.4")
      expect(vm.reload.ephemeral_net6.to_s).to eq("2a01:4f8:173:1ed3:aa7c::/79")
    end

    it "sets sshable host to mgmt NIC and ipv4_dns_name to data NIC when use_separate_management_nic is set" do
      refresh_frame(nx, new_values: {"use_separate_management_nic" => true})
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "running"}, network_interfaces: [
        {network_interface_id: "eni-mgmt", attachment: {device_index: 0}, association: {public_ip: "9.9.9.9", public_dns_name: "ec2-9-9-9-9.compute.amazonaws.com"}, ipv_6_addresses: []},
        {network_interface_id: "eni-0123456789abcdefg", attachment: {device_index: 1}, association: {public_ip: "1.2.3.4", public_dns_name: "ec2-1-2-3-4.compute.amazonaws.com"}, ipv_6_addresses: [{ipv_6_address: "2a01:4f8:173:1ed3:aa7c::/79"}]},
      ]}]}])
      expect { nx.wait_instance_created }.to hop("wait_sshable")
      expect(vm.sshable.reload.host).to eq("9.9.9.9")
      expect(aws_instance.reload.ipv4_dns_name).to eq("ec2-1-2-3-4.compute.amazonaws.com")
    end
  end

  describe "#wait_instance_created", "without sshable" do
    let(:vm) { vm_without_sshable }
    let(:aws_instance) { AwsInstance.create_with_id(vm, instance_id: "i-0123456789abcdefg") }

    before do
      aws_instance
      nic_aws_resource
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "running"}, network_interfaces: [{network_interface_id: "eni-0123456789abcdefg", association: {public_ip: "1.2.3.4"}, ipv_6_addresses: [{ipv_6_address: "2a01:4f8:173:1ed3:aa7c::/79"}]}]}]}])
    end

    it "handles vm without sshable" do
      expect { nx.wait_instance_created }
        .to hop("wait_sshable")
        .and change(client, :api_requests)
        .to(include(a_hash_including(
          operation_name: :describe_instances,
          params: a_hash_including(filters: [
            {name: "instance-id", values: ["i-0123456789abcdefg"]},
            {name: "tag:Ubicloud", values: ["true"]},
          ]),
        )))
        .and change { vm.reload.cores }.to(1)
    end
  end

  describe "#wait_old_nic_deleted" do
    let(:old_nic) { vm.user_nic }
    let(:private_subnet_id) { old_nic.private_subnet_id }

    before do
      refresh_frame(nx, new_values: {"private_subnet_id" => private_subnet_id, "unsupported_azs" => ["a"], "exclude_availability_zones" => ["b"]})
    end

    it "naps if old NIC still exists" do
      expect(vm.user_nic).to exist
      expect { nx.wait_old_nic_deleted }.to nap(1)
    end

    it "creates new NIC with combined exclusions and hops to wait_nic_recreated" do
      old_nic.update(vm_id: nil)
      vm.reload

      expect { nx.wait_old_nic_deleted }.to hop("wait_nic_recreated")
      expect(vm.reload.user_nic.id).not_to eq(old_nic.id)
      expect(vm.user_nic.strand.label).to eq("start")
      expect(vm.user_nic.strand.stack.first["exclude_availability_zones"]).to eq(["a", "b"])
    end

    it "creates both user and mgmt NICs when use_separate_management_nic is set" do
      old_nic.update(vm_id: nil)
      vm.reload
      refresh_frame(nx, new_values: {"private_subnet_id" => private_subnet_id, "use_separate_management_nic" => true})

      expect { nx.wait_old_nic_deleted }.to hop("wait_nic_recreated")
      expect(vm.reload.nics.count).to eq(2)
      expect(vm.user_nic).not_to be_nil
      expect(vm.management_nic).not_to be_nil
    end
  end

  describe "#wait_nic_recreated" do
    let(:nic) { vm.user_nic }

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

    it "probes the management NIC's EIP (sshable.host) when use_separate_management_nic is set" do
      refresh_frame(nx, new_values: {"use_separate_management_nic" => true})
      vm.sshable.update(host: "9.9.9.9")
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "10.0.0.1/32")
      vm.incr_update_firewall_rules
      expect(Socket).to receive(:tcp).with("9.9.9.9", 22, connect_timeout: 1)
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
      expect(nx).to receive(:retval).and_return({"msg" => "firewall rules synced"})
      expect { nx.update_firewall_rules }.to hop("wait")
    end
  end

  describe "#prevent_destroy" do
    it "registers a deadline and naps while preventing" do
      now = Time.now
      expect(Time).to receive(:now).at_least(:once).and_return(now)
      expect { nx.prevent_destroy }.to nap(30)
      expect(nx.strand.stack.first["deadline_target"]).to eq("destroy")
      expect(Time.parse(nx.strand.stack.first["deadline_at"])).to be_within(0.00001).of(now + 24 * 60 * 60)
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

  describe "#destroy", "with a single boot volume" do
    let(:storage_volumes) { [{encrypted: true, size_gib: 30}] }

    it "hops to cleanup_roles when there is no data volume" do
      aws_instance
      expect(client).to receive(:terminate_instances)
      expect { nx.destroy }.to hop("cleanup_roles")
    end
  end

  describe "network volumes" do
    let(:storage_volumes) {
      [{encrypted: true, size_gib: 30},
        {encrypted: true, size_gib: 256, network_volume_type: "gp3"},
        {encrypted: true, size_gib: 32, network_volume_type: "gp3"}]
    }

    let(:data_volume) { vm.vm_storage_volumes_dataset.first(disk_index: 1) }
    let(:wal_volume) { vm.vm_storage_volumes_dataset.first(disk_index: 2) }

    before { aws_instance }

    describe "#wait_instance_created" do
      it "stashes the az and hops to create_network_volumes" do
        nic_aws_resource
        client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "running"}, placement: {availability_zone: "us-west-2a"}, network_interfaces: [{network_interface_id: "eni-0123456789abcdefg", association: {public_ip: "1.2.3.4"}, ipv_6_addresses: [{ipv_6_address: "2a01:4f8:173:1ed3:aa7c::/79"}]}]}]}])
        expect { nx.wait_instance_created }.to hop("create_network_volumes")
        expect(nx.network_volume_az).to eq("us-west-2a")
      end
    end

    describe "#create_network_volumes" do
      before { refresh_frame(nx, new_values: {"network_volume_az" => "us-west-2a"}) }

      it "creates gp3 data and wal volumes and records their ids" do
        client.stub_responses(:create_volume, [{volume_id: "vol-0abc123"}, {volume_id: "vol-0wal456"}])
        expect { nx.create_network_volumes }.to hop("attach_network_volumes")
        expect(data_volume.reload.provider_volume_id).to eq("vol-0abc123")
        expect(wal_volume.reload.provider_volume_id).to eq("vol-0wal456")
        expect(client.api_requests).to include(
          a_hash_including(
            operation_name: :create_volume,
            params: a_hash_including(volume_type: "gp3", iops: 3000, throughput: 125, size: 256, availability_zone: "us-west-2a", encrypted: true),
          ),
          a_hash_including(
            operation_name: :create_volume,
            params: a_hash_including(volume_type: "gp3", iops: 3000, throughput: 125, size: 32, availability_zone: "us-west-2a", encrypted: true),
          ),
        )
      end

      it "skips creation when the ids are already recorded" do
        data_volume.update(provider_volume_id: "vol-existing")
        wal_volume.update(provider_volume_id: "vol-existing-wal")
        expect(client).not_to receive(:create_volume)
        expect { nx.create_network_volumes }.to hop("attach_network_volumes")
      end

      context "with io2" do
        let(:storage_volumes) {
          [{encrypted: true, size_gib: 30},
            {encrypted: true, size_gib: 256, network_volume_type: "io2"},
            {encrypted: true, size_gib: 32, network_volume_type: "gp3"}]
        }

        it "creates an io2 data volume without throughput, wal volume stays gp3" do
          client.stub_responses(:create_volume, [{volume_id: "vol-io2"}, {volume_id: "vol-wal"}])
          expect { nx.create_network_volumes }.to hop("attach_network_volumes")
          data_params, wal_params = client.api_requests.select { it[:operation_name] == :create_volume }.map { it[:params] }
          expect(data_params).to include(volume_type: "io2", iops: 3000)
          expect(data_params).not_to include(:throughput)
          expect(wal_params).to include(volume_type: "gp3", iops: 3000, throughput: 125)
        end
      end
    end

    describe "#attach_network_volumes" do
      before do
        data_volume.update(provider_volume_id: "vol-0abc123")
        wal_volume.update(provider_volume_id: "vol-0wal456")
      end

      it "attaches each volume when it is available, then naps" do
        client.stub_responses(:describe_volumes, volumes: [{state: "available"}])
        expect { nx.attach_network_volumes }.to nap(2)
        expect(client.api_requests).to include(
          a_hash_including(
            operation_name: :attach_volume,
            params: a_hash_including(device: "/dev/sdf", instance_id: "i-0123456789abcdefg", volume_id: "vol-0abc123"),
          ),
          a_hash_including(
            operation_name: :attach_volume,
            params: a_hash_including(device: "/dev/sdg", instance_id: "i-0123456789abcdefg", volume_id: "vol-0wal456"),
          ),
        )
      end

      it "tolerates the volume already attaching" do
        client.stub_responses(:describe_volumes, volumes: [{state: "available"}])
        client.stub_responses(:attach_volume, Aws::EC2::Errors::VolumeInUse.new(nil, "in use"))
        expect { nx.attach_network_volumes }.to nap(2)
      end

      it "naps while the volumes are still creating" do
        client.stub_responses(:describe_volumes, volumes: [{state: "creating"}])
        expect(client).not_to receive(:attach_volume)
        expect { nx.attach_network_volumes }.to nap(2)
      end

      it "naps while only some volumes are attached" do
        client.stub_responses(:describe_volumes, [{volumes: [{state: "in-use"}]}, {volumes: [{state: "available"}]}])
        expect { nx.attach_network_volumes }.to nap(2)
        expect(client.api_requests).to include(a_hash_including(
          operation_name: :attach_volume,
          params: a_hash_including(device: "/dev/sdg", volume_id: "vol-0wal456"),
        ))
      end

      it "hops to wait_sshable once all volumes are attached" do
        client.stub_responses(:describe_volumes, volumes: [{state: "in-use"}])
        expect { nx.attach_network_volumes }.to hop("wait_sshable")
      end
    end

    describe "#destroy" do
      it "hops to delete_network_volumes when the data volume has an aws id" do
        data_volume.update(provider_volume_id: "vol-0abc123")
        expect(client).to receive(:terminate_instances)
        expect { nx.destroy }.to hop("delete_network_volumes")
      end

      it "hops directly to cleanup_roles when no data volume was provisioned" do
        expect(client).to receive(:terminate_instances)
        expect { nx.destroy }.to hop("cleanup_roles")
      end
    end

    describe "#delete_network_volumes" do
      before do
        data_volume.update(provider_volume_id: "vol-0abc123")
        wal_volume.update(provider_volume_id: "vol-0wal456")
      end

      it "deletes each volume and hops to cleanup_roles" do
        expect(client).to receive(:delete_volume).with(volume_id: "vol-0abc123")
        expect(client).to receive(:delete_volume).with(volume_id: "vol-0wal456")
        expect { nx.delete_network_volumes }.to hop("cleanup_roles")
      end

      it "skips volumes that were never provisioned" do
        wal_volume.update(provider_volume_id: nil)
        expect(client).to receive(:delete_volume).with(volume_id: "vol-0abc123")
        expect { nx.delete_network_volumes }.to hop("cleanup_roles")
      end

      it "naps while a volume is still in use" do
        client.stub_responses(:delete_volume, Aws::EC2::Errors::VolumeInUse.new(nil, "in use"))
        expect { nx.delete_network_volumes }.to nap(5)
      end

      it "tolerates already deleted volumes" do
        client.stub_responses(:delete_volume, Aws::EC2::Errors::InvalidVolumeNotFound.new(nil, "not found"))
        expect { nx.delete_network_volumes }.to hop("cleanup_roles")
      end
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
        marker: "next-page-marker",
      })

      # Second page: has the policy we're looking for
      second_response = iam_client.stub_data(:list_policies, {
        policies: [{policy_name: "#{vm.name}-cw-agent-policy", arn: "arn:aws:iam::aws:policy/#{vm.name}-cw-agent-policy"}],
        is_truncated: false,
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
        marker: "next-page-marker",
      })

      # Second page: no match, last page
      second_response = iam_client.stub_data(:list_policies, {
        policies: [{policy_name: "other-policy-2", arn: "arn:aws:iam::aws:policy/other-policy-2"}],
        is_truncated: false,
      })

      iam_client.stub_responses(:list_policies, first_response, second_response)

      policy = nx.cloudwatch_policy
      expect(policy).to be_nil
      expect(iam_client.api_requests).to include(
        a_hash_including(operation_name: :list_policies, params: a_hash_including(scope: "Local", max_items: 100, marker: nil)),
        a_hash_including(operation_name: :list_policies, params: a_hash_including(scope: "Local", max_items: 100, marker: "next-page-marker")),
      )
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
        {policy_name: "policy-name", policy_arn: "policy-arn"},
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
          a_hash_including(operation_name: :delete_role, params: {role_name: "testvm"}),
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
          a_hash_including(operation_name: :delete_role, params: {role_name: "testvm"}),
        ))
    end

    it "deletes inline role policies before deleting the role" do
      iam_client.stub_responses(:list_policies, policies: [])
      iam_client.stub_responses(:remove_role_from_instance_profile, {})
      iam_client.stub_responses(:delete_instance_profile, {})
      iam_client.stub_responses(:list_role_policies, policy_names: ["guardduty-telemetry", "extra-inline"])
      iam_client.stub_responses(:delete_role_policy, {})
      iam_client.stub_responses(:delete_role, {})

      expect { nx.cleanup_roles }
        .to exit({"msg" => "vm destroyed"})
        .and change(iam_client, :api_requests)
        .to(include(
          a_hash_including(operation_name: :delete_role_policy, params: {role_name: "testvm", policy_name: "guardduty-telemetry"}),
          a_hash_including(operation_name: :delete_role_policy, params: {role_name: "testvm", policy_name: "extra-inline"}),
          a_hash_including(operation_name: :delete_role, params: {role_name: "testvm"}),
        ))
    end
  end
end
