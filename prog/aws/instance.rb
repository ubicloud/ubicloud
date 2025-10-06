# frozen_string_literal: true

class Prog::Aws::Instance < Prog::Base
  subject_is :vm, :aws_instance

  def before_run
    when_destroy_set? do
      pop "exiting early due to destroy semaphore"
    end
  end

  label def start
    # Cloudwatch is not needed for runner instances
    hop_create_instance if is_runner?

    assume_role_policy_document = {
      Version: "2012-10-17",
      Statement: [
        {
          Effect: "Allow",
          Principal: {Service: "ec2.amazonaws.com"},
          Action: "sts:AssumeRole"
        }
      ]
    }.to_json

    ignore_invalid_entity do
      iam_client.create_role({role_name:, assume_role_policy_document:})
    end

    hop_create_role_policy
  end

  label def create_role_policy
    policy_document = {
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

    ignore_invalid_entity do
      iam_client.create_policy({policy_name:, policy_document:})
    end

    hop_attach_role_policy
  end

  label def attach_role_policy
    ignore_invalid_entity do
      iam_client.attach_role_policy({role_name:, policy_arn: cloudwatch_policy.arn})
    end

    hop_create_instance_profile
  end

  label def create_instance_profile
    ignore_invalid_entity do
      iam_client.create_instance_profile({instance_profile_name:})
    end

    hop_add_role_to_instance_profile
  end

  label def add_role_to_instance_profile
    ignore_invalid_entity do
      iam_client.add_role_to_instance_profile({instance_profile_name:, role_name:})
    end

    hop_wait_instance_profile_created
  end

  label def wait_instance_profile_created
    begin
      iam_client.get_instance_profile({instance_profile_name:})
    rescue Aws::IAM::Errors::NoSuchEntity
      nap 1
    end
    hop_create_instance
  end

  label def create_instance
    public_keys = (vm.sshable.keys.map(&:public_key) + (vm.project.get_ff_vm_public_ssh_keys || [])).join("\n")
    # Define user data script to set a custom username
    user_data = <<~USER_DATA
      #!/bin/bash
      custom_user="#{vm.unix_user}"
      if [ ! -d /home/$custom_user ]; then
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
      fi
      echo #{public_keys.shellescape} > /home/$custom_user/.ssh/authorized_keys
      usermod -L ubuntu
    USER_DATA

    instance_market_options = nil
    if is_runner?
      # Normally we use dnsmasq to resolve our transparent cache domain to local IP, but we use /etc/hosts for AWS runners
      user_data += "\necho \"#{vm.private_ipv4} ubicloudhostplaceholder.blob.core.windows.net\" >> /etc/hosts"
      instance_market_options = if Config.github_runner_aws_spot_instance_enabled
        spot_options = {
          spot_instance_type: "one-time",
          instance_interruption_behavior: "terminate"
        }
        if Config.github_runner_aws_spot_instance_max_price_per_vcpu > 0
          # Not setting max_price means you'll pay up to the on-demand price,
          spot_options[:max_price] = (vm.vcpus * Config.github_runner_aws_spot_instance_max_price_per_vcpu * 60).to_s
        end
        {market_type: "spot", spot_options:}
      end
    end

    params = {
      image_id: vm.boot_image, # AMI ID
      instance_type: Option.aws_instance_type_name(vm.family, vm.vcpus),
      block_device_mappings: [
        {
          device_name: "/dev/sda1",
          ebs: {
            encrypted: true,
            delete_on_termination: true,
            iops: 3000,
            volume_size: vm.vm_storage_volumes_dataset.where(:boot).get(:size_gib),
            volume_type: "gp3",
            throughput: 125
          }
        }
      ],
      network_interfaces: [
        {
          network_interface_id: vm.nics.first.nic_aws_resource.network_interface_id,
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
      user_data: Base64.encode64(user_data.gsub(/^(\s*# .*)?\n/, "")),
      tag_specifications: Util.aws_tag_specifications("instance", vm.name),
      client_token: vm.id,
      instance_market_options:
    }
    params[:iam_instance_profile] = {name: instance_profile_name} unless is_runner?
    begin
      instance_response = client.run_instances(params)
    rescue Aws::EC2::Errors::InvalidParameterValue => e
      nap 1 if e.message.include?("Invalid IAM Instance Profile name")
      raise
    rescue Aws::EC2::Errors::InsufficientInstanceCapacity => e
      if is_runner? && (runner = GithubRunner[vm_id: vm.id])
        next_family = if (families = frame["alternative_families"])
          index = families.index(vm.family) || -1
          families[index + 1]
        end
        Clog.emit("insufficient instance capacity") { {insufficient_instance_capacity: {vm:, next_family:, message: e.message}} }
        if next_family
          vm.update(family: next_family)
          nap 0
        end
        runner.provision_spare_runner
        runner.incr_destroy
        pop "exiting due to insufficient instance capacity"
      end
      raise
    end
    instance = instance_response.instances.first
    instance_id = instance.instance_id
    subnet_id = instance.network_interfaces.first.subnet_id
    subnet_response = client.describe_subnets(subnet_ids: [subnet_id])
    az_id = subnet_response.subnets.first.availability_zone_id
    ipv4_dns_name = instance.public_dns_name

    AwsInstance.create_with_id(vm.id, instance_id:, az_id:, ipv4_dns_name:)

    hop_wait_instance_created
  end

  label def wait_instance_created
    instance_response = client.describe_instances({filters: [{name: "instance-id", values: [aws_instance.instance_id]}, {name: "tag:Ubicloud", values: ["true"]}]}).reservations[0].instances[0]
    nap 1 unless instance_response.dig(:state, :name) == "running"

    public_ipv4 = instance_response.dig(:network_interfaces, 0, :association, :public_ip)
    public_ipv6 = instance_response.dig(:network_interfaces, 0, :ipv_6_addresses, 0, :ipv_6_address)
    AssignedVmAddress.create(dst_vm_id: vm.id, ip: public_ipv4)
    vm.sshable&.update(host: public_ipv4)
    vm.update(cores: vm.vcpus / 2, allocated_at: Time.now, ephemeral_net6: public_ipv6)

    pop "vm created"
  end

  label def destroy
    if aws_instance
      begin
        client.terminate_instances(instance_ids: [aws_instance.instance_id])
      rescue Aws::EC2::Errors::InvalidInstanceIDNotFound
      end

      aws_instance.destroy
    end

    pop "vm destroyed" if is_runner?

    hop_cleanup_roles
  end

  label def cleanup_roles
    ignore_invalid_entity do
      iam_client.remove_role_from_instance_profile({instance_profile_name:, role_name:})
    end
    ignore_invalid_entity do
      iam_client.delete_instance_profile({instance_profile_name:})
    end

    if cloudwatch_policy
      ignore_invalid_entity do
        iam_client.detach_role_policy({role_name:, policy_arn: cloudwatch_policy.arn})
      end

      ignore_invalid_entity do
        iam_client.delete_policy({policy_arn: cloudwatch_policy.arn})
      end
    end

    ignore_invalid_entity do
      iam_client.delete_role({role_name:})
    end

    pop "vm destroyed"
  end

  def client
    @client ||= vm.location.location_credential.client
  end

  def iam_client
    @iam_client ||= vm.location.location_credential.iam_client
  end

  def cloudwatch_policy
    @cloudwatch_policy ||= iam_client.list_policies(scope: "Local").policies.find { |p| p.policy_name == policy_name }
  end

  def policy_name
    "#{vm.name}-cw-agent-policy"
  end

  def role_name
    vm.name
  end

  def instance_profile_name
    "#{vm.name}-instance-profile"
  end

  def is_runner?
    @is_runner ||= vm.unix_user == "runneradmin"
  end

  def ignore_invalid_entity
    yield
  rescue Aws::IAM::Errors::InvalidInstanceProfileName,
    Aws::IAM::Errors::InvalidRoleName,
    Aws::IAM::Errors::NoSuchEntity,
    Aws::IAM::Errors::EntityAlreadyExists => e
    Clog.emit("ID not found or already exists for aws instance") { {ignored_aws_instance_failure: {exception: Util.exception_to_hash(e, backtrace: nil)}} }
  end
end
