# frozen_string_literal: true

RSpec.describe Prog::Vm::Aws::Nexus do
  subject(:nx) {
    described_class.new(vm.strand).tap {
      it.instance_variable_set(:@vm, vm)
      it.instance_variable_set(:@aws_instance, aws_instance)
    }
  }

  let(:st) {
    vm.strand
  }

  let(:vm) {
    prj = Project.create(name: "test-prj")
    loc = Location.create(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US East 1", visible: true)
    LocationCredential.create_with_id(loc, access_key: "test-access-key", secret_key: "test-secret-key")
    storage_volumes = [
      {encrypted: true, size_gib: 30},
      {encrypted: true, size_gib: 3800}
    ]
    Prog::Vm::Nexus.assemble("dummy-public key", prj.id, location_id: loc.id, unix_user: "test-user-aws", boot_image: "ami-030c060f85668b37d", name: "testvm", size: "m6gd.large", arch: "arm64", storage_volumes:).subject
  }

  let(:aws_instance) { AwsInstance.create_with_id(vm, instance_id: "i-0123456789abcdefg") }

  let(:client) { Aws::EC2::Client.new(stub_responses: true) }

  let(:iam_client) { Aws::IAM::Client.new(stub_responses: true) }

  let(:user_data) {
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
echo dummy-public-key > /home/$custom_user/.ssh/authorized_keys
usermod -L ubuntu
    USER_DATA
  }

  before do
    allow(nx).to receive_messages(vm:, aws_instance:)
    allow(Aws::EC2::Client).to receive(:new).with(credentials: anything, region: "us-west-2").and_return(client)
    allow(Aws::IAM::Client).to receive(:new).with(credentials: anything, region: "us-west-2").and_return(iam_client)
  end

  describe ".assemble" do
    let(:project) { Project.create(name: "test-prj") }

    it "creates correct number of storage volumes for storage optimized instance types" do
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "us-west-2", ui_name: "us-west-2", visible: true)
      storage_volumes = [
        {encrypted: true, size_gib: 30},
        {encrypted: true, size_gib: 7500}
      ]

      vm = Prog::Vm::Nexus.assemble("some_ssh key", project.id, location_id: loc.id, size: "i8g.8xlarge", arch: "arm64", storage_volumes:).subject
      expect(vm.vm_storage_volumes.count).to eq(3)
    end

    it "hops to start_aws if location is aws" do
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "us-west-2", ui_name: "us-west-2", visible: true)
      st = Prog::Vm::Nexus.assemble("some_ssh key", project.id, location_id: loc.id)
      expect(st.label).to eq("start")
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      ["destroy", "cleanup_roles"].each do |label|
        expect(nx).to receive(:when_destroy_set?).and_yield
        st.label = label
        expect { nx.before_run }.not_to hop("destroy")
      end
    end

    it "stops billing before hops to destroy" do
      br = BillingRecord.create(
        project_id: vm.project.id,
        resource_id: vm.id,
        resource_name: vm.name,
        billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
        amount: vm.vcpus
      )

      expect(vm).to receive(:active_billing_records).and_return([br])
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(br).to receive(:finalize)
      expect { nx.before_run }.to hop("destroy")
    end

    it "hops to destroy if billing record is not found" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(vm.active_billing_records).to be_empty
      expect { nx.before_run }.to hop("destroy")
    end
  end

  describe "#start" do
    it "naps if vm nics are not in wait state" do
      vm.nics.first.strand.update(label: "start")
      expect { nx.start }.to nap(1)
    end

    it "creates a role for instance" do
      vm.nics.first.strand.update(label: "wait")
      iam_client.stub_responses(:create_role, {})
      allow(nx).to receive(:iam_client).and_return(iam_client)
      iam_client.stub_responses(:create_role, {})
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
      })

      expect { nx.start }.to hop("create_role_policy")
    end

    it "hops to create_role_policy if role already exists" do
      vm.nics.first.strand.update(label: "wait")
      allow(nx).to receive(:iam_client).and_return(iam_client)
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
      })

      expect { nx.create_role_policy }.to hop("attach_role_policy")
    end

    it "hops to attach_role_policy if policy already exists" do
      allow(nx).to receive(:iam_client).and_return(iam_client)
      expect(iam_client).to receive(:create_policy).and_raise(Aws::IAM::Errors::EntityAlreadyExists.new(nil, "EntityAlreadyExists"))
      expect { nx.create_role_policy }.to hop("attach_role_policy")
    end
  end

  describe "#attach_role_policy" do
    it "attaches role policy" do
      allow(nx).to receive(:iam_client).and_return(iam_client)
      iam_client.stub_responses(:attach_role_policy, {})
      iam_client.stub_responses(:list_policies, policies: [{policy_name: "#{vm.name}-cw-agent-policy", arn: "arn:aws:iam::aws:policy/#{vm.name}-cw-agent-policy"}])
      expect(iam_client).to receive(:attach_role_policy).with({
        role_name: vm.name,
        policy_arn: "arn:aws:iam::aws:policy/#{vm.name}-cw-agent-policy"
      })

      expect { nx.attach_role_policy }.to hop("create_instance_profile")
    end

    it "hops to create_instance_profile if policy already exists" do
      allow(nx).to receive(:iam_client).and_return(iam_client)
      iam_client.stub_responses(:list_policies, policies: [{policy_name: "#{vm.name}-cw-agent-policy", arn: "arn:aws:iam::aws:policy/#{vm.name}-cw-agent-policy"}])
      expect(iam_client).to receive(:attach_role_policy).and_raise(Aws::IAM::Errors::EntityAlreadyExists.new(nil, "EntityAlreadyExists"))
      expect { nx.attach_role_policy }.to hop("create_instance_profile")
    end
  end

  describe "#create_instance_profile" do
    it "creates an instance profile" do
      allow(nx).to receive(:iam_client).and_return(iam_client)
      iam_client.stub_responses(:create_instance_profile, {})
      expect(iam_client).to receive(:create_instance_profile).with({
        instance_profile_name: "#{vm.name}-instance-profile"
      })

      expect { nx.create_instance_profile }.to hop("add_role_to_instance_profile")
    end

    it "hops to add_role_to_instance_profile if instance profile already exists" do
      allow(nx).to receive(:iam_client).and_return(iam_client)
      expect(iam_client).to receive(:create_instance_profile).and_raise(Aws::IAM::Errors::EntityAlreadyExists.new(nil, "EntityAlreadyExists"))
      expect { nx.create_instance_profile }.to hop("add_role_to_instance_profile")
    end
  end

  describe "#add_role_to_instance_profile" do
    it "adds role to instance profile" do
      allow(nx).to receive(:iam_client).and_return(iam_client)
      iam_client.stub_responses(:add_role_to_instance_profile, {})
      expect(iam_client).to receive(:add_role_to_instance_profile).with({
        instance_profile_name: "#{vm.name}-instance-profile",
        role_name: vm.name
      })

      expect { nx.add_role_to_instance_profile }.to hop("wait_instance_profile_created")
    end

    it "hops to wait_instance_profile_created if role is already added to instance profile" do
      allow(nx).to receive(:iam_client).and_return(iam_client)
      expect(iam_client).to receive(:add_role_to_instance_profile).and_raise(Aws::IAM::Errors::EntityAlreadyExists.new(nil, "LimitExceeded"))
      expect { nx.add_role_to_instance_profile }.to hop("wait_instance_profile_created")
    end
  end

  describe "#wait_instance_profile_created" do
    it "waits for instance profile to be created" do
      expect(nx).to receive(:iam_client).and_return(iam_client)

      iam_client.stub_responses(:get_instance_profile, instance_profile: {instance_profile_name: "#{vm.name}-instance-profile", instance_profile_id: "#{vm.name}-instance-profile-id", path: "/", roles: [], arn: "arn:aws:iam::#{vm.project.id}:instance-profile/#{vm.name}-instance-profile", create_date: Time.now})
      expect { nx.wait_instance_profile_created }.to hop("create_instance")
    end

    it "naps if instance profile is not created" do
      expect(nx).to receive(:iam_client).and_return(iam_client)
      expect(iam_client).to receive(:get_instance_profile).and_raise(Aws::IAM::Errors::NoSuchEntity.new(nil, "NoSuchEntity"))

      expect { nx.wait_instance_profile_created }.to nap(1)
    end
  end

  describe "#create_instance" do
    it "creates an instance" do
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
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
        user_data: Base64.encode64(user_data),
        tag_specifications: Util.aws_tag_specifications("instance", vm.name),
        iam_instance_profile: {
          name: "#{vm.name}-instance-profile"
        },
        client_token: vm.id,
        instance_market_options: nil
      }).and_call_original
      expect(AwsInstance).to receive(:create_with_id).with(vm, instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
      expect { nx.create_instance }.to hop("wait_instance_created")
    end

    it "skips instance profile creation for runner instances" do
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      client.stub_responses(:describe_subnets, subnets: [{availability_zone_id: "use1-az1"}])
      vm.update(unix_user: "runneradmin")
      expect(vm).to receive(:sshable).and_return(instance_double(Sshable, keys: [instance_double(SshKey, public_key: "dummy-public-key")]))
      expect(vm.nics.first).to receive(:nic_aws_resource).and_return(instance_double(NicAwsResource, network_interface_id: "eni-0123456789abcdefg"))
      expect(client).to receive(:run_instances).with(hash_not_including(:iam_instance_profile)).and_call_original
      expect(AwsInstance).to receive(:create_with_id).with(vm, instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
      expect { nx.create_instance }.to hop("wait_instance_created")
    end

    it "naps until instance profile not propagated yet" do
      client.stub_responses(:run_instances, Aws::EC2::Errors::InvalidParameterValue.new(nil, "Invalid IAM Instance Profile name"))
      client.stub_responses(:describe_subnets, subnets: [{availability_zone_id: "use1-az1"}])
      expect(vm).to receive(:sshable).and_return(instance_double(Sshable, keys: [instance_double(SshKey, public_key: "dummy-public-key")]))
      expect(vm.nics.first).to receive(:nic_aws_resource).and_return(instance_double(NicAwsResource, network_interface_id: "eni-0123456789abcdefg"))
      expect { nx.create_instance }.to nap(1)
    end

    it "raises exception if it's not for invalid instance profile" do
      client.stub_responses(:run_instances, Aws::EC2::Errors::InvalidParameterValue.new(nil, "Invalid instance name"))
      client.stub_responses(:describe_subnets, subnets: [{availability_zone_id: "use1-az1"}])
      expect(vm).to receive(:sshable).and_return(instance_double(Sshable, keys: [instance_double(SshKey, public_key: "dummy-public-key")]))
      expect(vm.nics.first).to receive(:nic_aws_resource).and_return(instance_double(NicAwsResource, network_interface_id: "eni-0123456789abcdefg"))
      expect { nx.create_instance }.to raise_error(Aws::EC2::Errors::InvalidParameterValue)
    end

    it "sets transparent cache host for runners" do
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      client.stub_responses(:describe_subnets, subnets: [{availability_zone_id: "use1-az1"}])
      expect(vm).to receive(:private_ipv4).and_return("1.2.3.4")
      vm.update(unix_user: "runneradmin")
      expect(vm).to receive(:sshable).and_return(instance_double(Sshable, keys: [instance_double(SshKey, public_key: "dummy-public-key")]))
      new_data = user_data + "echo \"1.2.3.4 ubicloudhostplaceholder.blob.core.windows.net\" >> /etc/hosts"
      expect(vm.nics.first).to receive(:nic_aws_resource).and_return(instance_double(NicAwsResource, network_interface_id: "eni-0123456789abcdefg"))
      expect(client).to receive(:run_instances).with(hash_including(user_data: Base64.encode64(new_data))).and_call_original
      expect(AwsInstance).to receive(:create_with_id).with(vm, instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
      expect { nx.create_instance }.to hop("wait_instance_created")
    end

    it "uses spot instances for runners when enabled" do
      expect(Config).to receive(:github_runner_aws_spot_instance_enabled).and_return(true)
      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      client.stub_responses(:describe_subnets, subnets: [{availability_zone_id: "use1-az1"}])
      expect(vm).to receive(:private_ipv4).and_return("1.2.3.4")
      vm.update(unix_user: "runneradmin")
      expect(vm).to receive(:sshable).and_return(instance_double(Sshable, keys: [instance_double(SshKey, public_key: "dummy-public-key")]))
      new_data = user_data + "echo \"1.2.3.4 ubicloudhostplaceholder.blob.core.windows.net\" >> /etc/hosts"
      expect(vm.nics.first).to receive(:nic_aws_resource).and_return(instance_double(NicAwsResource, network_interface_id: "eni-0123456789abcdefg"))
      expect(client).to receive(:run_instances).with(hash_including(
        user_data: Base64.encode64(new_data),
        instance_market_options: {market_type: "spot", spot_options: {instance_interruption_behavior: "terminate", spot_instance_type: "one-time"}}
      )).and_call_original
      expect(AwsInstance).to receive(:create_with_id).with(vm, instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
      expect { nx.create_instance }.to hop("wait_instance_created")
    end

    it "sets max price for spot instances if provided" do
      expect(Config).to receive(:github_runner_aws_spot_instance_enabled).and_return(true)
      expect(Config).to receive(:github_runner_aws_spot_instance_max_price_per_vcpu).and_return(0.001).at_least(:once)

      client.stub_responses(:run_instances, instances: [{instance_id: "i-0123456789abcdefg", network_interfaces: [{subnet_id: "subnet-12345678"}], public_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"}])
      client.stub_responses(:describe_subnets, subnets: [{availability_zone_id: "use1-az1"}])
      expect(vm).to receive(:private_ipv4).and_return("1.2.3.4")
      vm.update(unix_user: "runneradmin")
      expect(vm).to receive(:sshable).and_return(instance_double(Sshable, keys: [instance_double(SshKey, public_key: "dummy-public-key")]))
      new_data = user_data + "echo \"1.2.3.4 ubicloudhostplaceholder.blob.core.windows.net\" >> /etc/hosts"
      expect(vm.nics.first).to receive(:nic_aws_resource).and_return(instance_double(NicAwsResource, network_interface_id: "eni-0123456789abcdefg"))
      expect(client).to receive(:run_instances).with(hash_including(
        user_data: Base64.encode64(new_data),
        instance_market_options: {market_type: "spot", spot_options: {instance_interruption_behavior: "terminate", spot_instance_type: "one-time", max_price: "0.12"}}
      )).and_call_original
      expect(AwsInstance).to receive(:create_with_id).with(vm, instance_id: "i-0123456789abcdefg", az_id: "use1-az1", iam_role: "testvm", ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
      expect { nx.create_instance }.to hop("wait_instance_created")
    end

    describe "when insufficient capacity error" do
      before do
        client.stub_responses(:run_instances, Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "Insufficient capacity for instance type"))
        vm.update(unix_user: "runneradmin")
        installation = GithubInstallation.create(name: "ubicloud", type: "Organization", installation_id: 123, project_id: vm.project_id)
        GithubRunner.create(label: "ubicloud-standard-2", repository_name: "ubicloud/test", installation_id: installation.id, vm_id: vm.id)
        expect(vm).to receive(:sshable).and_return(instance_double(Sshable, keys: [instance_double(SshKey, public_key: "dummy-public-key")]))
        expect(vm.nics.first).to receive(:nic_aws_resource).and_return(instance_double(NicAwsResource, network_interface_id: "eni-0123456789abcdefg"))
        expect(Clog).to receive(:emit).with("insufficient instance capacity").and_call_original
      end

      it "recreates runner when alternative_families is not set" do
        expect(nx).to receive(:frame).and_return({}).at_least(:once)
        expect(Prog::Github::GithubRunnerNexus).to receive(:assemble).and_call_original
        expect { nx.create_instance }.to nap(0)
      end

      it "recreates runner when alternative_families is empty" do
        expect(nx).to receive(:frame).and_return({"alternative_families" => []}).at_least(:once)
        expect(Prog::Github::GithubRunnerNexus).to receive(:assemble).and_call_original
        expect { nx.create_instance }.to nap(0)
      end

      it "creates runner with the first alternative when current_family is the initial family" do
        expect(nx).to receive(:frame).and_return({"alternative_families" => ["m7i", "m6a"]}).at_least(:once)
        expect { nx.create_instance }.to nap(0)
        expect(vm.family).to eq("m7i")
      end

      it "creates runner with the next alternative when current_family is the first family" do
        vm.update(family: "m7i")
        expect(nx).to receive(:frame).and_return({"alternative_families" => ["m7i", "m6a"]}).at_least(:once)
        expect { nx.create_instance }.to nap(0)
        expect(vm.family).to eq("m6a")
      end

      it "recreates runner when current_family is the last family" do
        vm.update(family: "m6a")
        expect(nx).to receive(:frame).and_return({"alternative_families" => ["m7i", "m6a"]}).at_least(:once)
        expect(Prog::Github::GithubRunnerNexus).to receive(:assemble).and_call_original
        expect { nx.create_instance }.to nap(0)
      end
    end

    it "fails if not runner when encountering insufficient capacity error" do
      client.stub_responses(:run_instances, Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "Insufficient capacity for instance type"))
      expect(vm).to receive(:sshable).and_return(instance_double(Sshable, keys: [instance_double(SshKey, public_key: "dummy-public-key")]))
      expect(vm.nics.first).to receive(:nic_aws_resource).and_return(instance_double(NicAwsResource, network_interface_id: "eni-0123456789abcdefg"))
      expect { nx.create_instance }.to raise_error(Aws::EC2::Errors::InsufficientInstanceCapacity)
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
      expect { nx.wait_instance_created }.to hop("wait_sshable")
    end

    it "updates the vm with the instance id and updates ip according to the sshable" do
      time = Time.now
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      sshable = instance_double(Sshable)
      expect(vm).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:update).with(host: "1.2.3.4")
      expect(vm).to receive(:update).with(cores: 1, allocated_at: time, ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
      expect { nx.wait_instance_created }.to hop("wait_sshable")
    end

    it "naps if the instance is not running" do
      client.stub_responses(:describe_instances, reservations: [{instances: [{state: {name: "pending"}}]}])
      expect { nx.wait_instance_created }.to nap(1)
    end
  end

  describe "#wait_sshable" do
    it "naps 6 seconds if it's the first time we execute wait_sshable" do
      expect { nx.wait_sshable }.to nap(6)
        .and change { vm.reload.update_firewall_rules_set? }.from(false).to(true)
    end

    it "naps if not sshable" do
      expect(vm).to receive(:ip4).and_return(NetAddr::IPv4.parse("10.0.0.1"))
      vm.incr_update_firewall_rules
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1).and_raise Errno::ECONNREFUSED
      expect { nx.wait_sshable }.to nap(1)
    end

    it "hops to create_billing_record if sshable" do
      vm.incr_update_firewall_rules
      expect(vm).to receive(:ip4).and_return(NetAddr::IPv4.parse("10.0.0.1"))
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
      expect(Time).to receive(:now).and_return(now).at_least(:once)
      vm.update(allocated_at: now - 100)
      expect(Clog).to receive(:emit).with("vm provisioned").and_yield
    end

    it "not create billing records when the project is not billable" do
      vm.project.update(billable: false)
      expect { nx.create_billing_record }.to hop("wait")
      expect(BillingRecord.count).to eq(0)
    end

    it "creates billing records for only vm" do
      expect { nx.create_billing_record }.to hop("wait")
        .and change(BillingRecord, :count).from(0).to(1)
      expect(vm.active_billing_records.first.billing_rate["resource_type"]).to eq("VmVCpu")
      expect(vm.display_state).to eq("running")
      expect(vm.provisioned_at).to eq(now)
    end
  end

  describe "#wait" do
    it "naps when nothing to do" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to update_firewall_rules when needed" do
      expect(nx).to receive(:when_update_firewall_rules_set?).and_yield
      expect { nx.wait }.to hop("update_firewall_rules")
    end
  end

  describe "#update_firewall_rules" do
    it "hops to wait_firewall_rules" do
      vm.incr_update_firewall_rules
      expect(vm).to receive(:location).and_return(instance_double(Location, aws?: true))
      expect(nx).to receive(:push).with(Prog::Vnet::Aws::UpdateFirewallRules, {}, :update_firewall_rules)
      expect(nx).to receive(:decr_update_firewall_rules).and_call_original
      nx.update_firewall_rules
    end

    it "hops to wait if firewall rules are applied" do
      expect(nx).to receive(:retval).and_return({"msg" => "firewall rule is added"})
      expect { nx.update_firewall_rules }.to hop("wait")
    end
  end

  describe "#prevent_destroy" do
    it "registers a deadline and naps while preventing" do
      expect(nx).to receive(:register_deadline)
      expect { nx.prevent_destroy }.to nap(30)
    end
  end

  describe "#destroy" do
    it "prevents destroy if the semaphore set" do
      expect(nx).to receive(:when_prevent_destroy_set?).and_yield
      expect(Clog).to receive(:emit).with("Destroy prevented by the semaphore").and_call_original
      expect { nx.destroy }.to hop("prevent_destroy")
    end

    it "deletes the instance" do
      expect(aws_instance).to receive(:destroy)
      expect(client).to receive(:terminate_instances).with({instance_ids: ["i-0123456789abcdefg"]})
      expect { nx.destroy }.to hop("cleanup_roles")
    end

    it "pops directly if there is no aws_instance" do
      expect(nx).to receive(:aws_instance).and_return(nil)
      expect { nx.destroy }.to hop("cleanup_roles")
    end

    it "exits directly if it's a runner" do
      vm.update(unix_user: "runneradmin")
      expect { nx.destroy }.to exit({"msg" => "vm destroyed"})
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
      expect(iam_client).to receive(:detach_role_policy).with({policy_arn: "arn:aws:iam::aws:policy/testvm-cw-agent-policy", role_name: "testvm"})
      expect(iam_client).to receive(:detach_role_policy).with({role_name: vm.name, policy_arn: "policy-arn"})

      expect { nx.cleanup_roles }.to exit({"msg" => "vm destroyed"})
    end

    it "skips policy cleanup if the cloudwatch policy doesn't exist" do
      iam_client.stub_responses(:list_policies, policies: [])
      iam_client.stub_responses(:remove_role_from_instance_profile, {})
      iam_client.stub_responses(:delete_instance_profile, {})
      iam_client.stub_responses(:delete_role, {})
      expect { nx.cleanup_roles }.to exit({"msg" => "vm destroyed"})
    end
  end
end
