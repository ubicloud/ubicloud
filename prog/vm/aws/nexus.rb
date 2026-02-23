# frozen_string_literal: true

class Prog::Vm::Aws::Nexus < Prog::Base
  subject_is :vm, :aws_instance

  def before_destroy
    register_deadline(nil, 5 * 60)
    vm.active_billing_records.each(&:finalize)
  end

  label def start
    register_deadline("wait", 10 * 60)
    nap 1 unless nic.strand.label == "wait"
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
      echo #{NetSsh.command(":public_keys", public_keys:)} > /home/$custom_user/.ssh/authorized_keys
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
      image_id: aws_ami_id,
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
          network_interface_id: nic.nic_aws_resource.network_interface_id,
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
        Clog.emit("insufficient instance capacity", {insufficient_instance_capacity: {vm:, next_family:, message: e.message}})
        if next_family
          vm.update(family: next_family)
          nap 0
        end
        runner.provision_spare_runner
        runner.incr_destroy
        nap 60
      end

      retry_in_different_az(e)
    rescue Aws::EC2::Errors::Unsupported => e
      retry_in_different_az(e)
    end
    instance = instance_response.instances.first
    instance_id = instance.instance_id
    subnet_id = instance.network_interfaces.first.subnet_id
    subnet_response = client.describe_subnets(subnet_ids: [subnet_id])
    az_id = subnet_response.subnets.first.availability_zone_id
    ipv4_dns_name = instance.public_dns_name

    AwsInstance.create_with_id(vm, instance_id:, az_id:, ipv4_dns_name:, iam_role: role_name)

    hop_wait_instance_created
  end

  label def wait_old_nic_deleted
    nap 1 if nic&.reload
    nic = Prog::Vnet::NicNexus.assemble(frame["private_subnet_id"], name: vm.name + "-nic", exclude_availability_zones: frame["exclude_availability_zones"]).subject
    nic.update(vm_id: vm.id)
    hop_wait_nic_recreated
  end

  label def wait_nic_recreated
    nap 1 unless nic.strand.label == "wait"
    hop_create_instance
  end

  label def wait_instance_created
    unless (reservation = client.describe_instances({filters: [{name: "instance-id", values: [aws_instance.instance_id]}, {name: "tag:Ubicloud", values: ["true"]}]}).reservations.first) &&
        (instance_response = reservation.instances.first) &&
        instance_response.dig(:state, :name) == "running"
      nap 1
    end
    public_ipv4 = instance_response.dig(:network_interfaces, 0, :association, :public_ip)
    public_ipv6 = instance_response.dig(:network_interfaces, 0, :ipv_6_addresses, 0, :ipv_6_address)
    AssignedVmAddress.create(dst_vm_id: vm.id, ip: public_ipv4)
    vm.sshable&.update(host: public_ipv4)
    vm.update(cores: vm.vcpus / 2, allocated_at: Time.now, ephemeral_net6: public_ipv6)

    hop_wait_sshable
  end

  label def wait_sshable
    unless vm.update_firewall_rules_set?
      vm.incr_update_firewall_rules
      # This is the first time we get into this state and we know that
      # wait_sshable will take definitely more than 6 seconds. So, we nap here
      # to reduce the amount of load on the control plane unnecessarily.
      nap 6
    end
    addr = vm.ip4
    hop_create_billing_record unless addr

    begin
      Socket.tcp(addr.to_s, 22, connect_timeout: 1) {}
    rescue SystemCallError
      nap 1
    end

    hop_create_billing_record
  end

  label def create_billing_record
    vm.update(display_state: "running", provisioned_at: Time.now)

    Clog.emit("vm provisioned", [vm, {provision: {vm_ubid: vm.ubid, instance_id: vm.aws_instance.instance_id, duration: (Time.now - vm.allocated_at).round(3)}}])

    project = vm.project
    hop_wait unless project.billable

    BillingRecord.create(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
      amount: vm.vcpus
    )

    hop_wait
  end

  label def wait
    when_update_firewall_rules_set? do
      register_deadline("wait", 5 * 60)
      hop_update_firewall_rules
    end

    nap 6 * 60 * 60
  end

  label def update_firewall_rules
    if retval&.dig("msg") == "firewall rule is added"
      hop_wait
    end

    decr_update_firewall_rules
    push vm.update_firewall_rules_prog, {}, :update_firewall_rules
  end

  label def prevent_destroy
    register_deadline("destroy", 24 * 60 * 60)
    nap 30
  end

  label def destroy
    decr_destroy

    when_prevent_destroy_set? do
      Clog.emit("Destroy prevented by the semaphore")
      hop_prevent_destroy
    end

    vm.update(display_state: "deleting")

    if aws_instance
      begin
        client.terminate_instances(instance_ids: [aws_instance.instance_id])
      rescue Aws::EC2::Errors::InvalidInstanceIDNotFound
      end

      aws_instance.destroy
    end

    if is_runner?
      final_clean_up
      pop "vm destroyed"
    end

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

    if Config.aws_postgres_iam_access
      ignore_invalid_entity do
        iam_client.list_attached_role_policies(role_name:).attached_policies.each do |policy|
          ignore_invalid_entity do
            iam_client.detach_role_policy(role_name:, policy_arn: policy.policy_arn)
          end
        end
      end
    end

    ignore_invalid_entity do
      iam_client.delete_role({role_name:})
    end

    final_clean_up
    pop "vm destroyed"
  end

  def final_clean_up
    nic.update(vm_id: nil)
    nic.incr_destroy
    vm.destroy
  end

  def nic
    @nic ||= vm.nic
  end

  def client
    @client ||= vm.location.location_credential.client
  end

  def iam_client
    @iam_client ||= vm.location.location_credential.iam_client
  end

  def cloudwatch_policy
    @cloudwatch_policy ||= begin
      marker = nil
      found_policy = nil
      loop do
        response = iam_client.list_policies(scope: "Local", marker:, max_items: 100)
        policy = response.policies.find { |p| p.policy_name == policy_name }
        if policy
          found_policy = policy
          break
        end

        break unless response.is_truncated
        marker = response.marker
      end
      found_policy
    end
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
    return @is_runner if defined?(@is_runner)
    @is_runner = vm.unix_user == "runneradmin"
  end

  CANONICAL_OWNER = "099720109477"
  BOOT_IMAGE_NAMES = {
    "ubuntu-noble" => "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-ARCH-server-*",
    "ubuntu-jammy" => "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-ARCH-server-*"
  }.freeze

  def aws_ami_id
    return vm.boot_image if vm.boot_image&.start_with?("ami-")

    pattern = BOOT_IMAGE_NAMES[vm.boot_image]
    raise "Unknown boot image '#{vm.boot_image}' — expected an ami-* ID or one of: #{BOOT_IMAGE_NAMES.keys.join(", ")}" unless pattern

    ami_arch = (vm.arch == "arm64") ? "arm64" : "amd64"
    resp = client.describe_images(
      filters: [
        {name: "name", values: [pattern.sub("ARCH", ami_arch)]},
        {name: "owner-id", values: [CANONICAL_OWNER]},
        {name: "state", values: ["available"]}
      ]
    )
    ami = resp.images.max_by(&:creation_date)
    raise "No AMI found matching '#{vm.boot_image}' (#{ami_arch}) in #{vm.location.name}" unless ami

    ami.image_id
  end

  def retry_in_different_az(e)
    if (retry_count = frame["retry_count"] || 0) >= 5
      Clog.emit("resetting excluding azs to retry", {retry_different_az_failed: {vm:, error: e.class.name, message: e.message, retry_count:}})
      update_stack({"exclude_availability_zones" => nil, "retry_count" => 0})
      nap 5 * 60
    end

    Clog.emit("retrying in different az", {retry_different_az: {vm:, error: e.class.name, message: e.message, retry_count: retry_count + 1}})
    azs_excluded = ((nic.strand.stack.first["exclude_availability_zones"] || []) + [nic.nic_aws_resource.subnet_az]).uniq
    update_stack({"exclude_availability_zones" => azs_excluded, "retry_count" => retry_count + 1})
    nic.incr_destroy
    hop_wait_old_nic_deleted
  end

  def ignore_invalid_entity
    yield
  rescue Aws::IAM::Errors::InvalidInstanceProfileName,
    Aws::IAM::Errors::InvalidRoleName,
    Aws::IAM::Errors::NoSuchEntity,
    Aws::IAM::Errors::EntityAlreadyExists => e
    Clog.emit("ID not found or already exists for aws instance", {ignored_aws_instance_failure: Util.exception_to_hash(e, backtrace: nil)})
  end
end
