# frozen_string_literal: true

require "aws-sdk-elasticloadbalancingv2"

class Prog::Postgres::PostgresPrivatelinkAwsNexus < Prog::Base
  subject_is :postgres_privatelink_aws_resource

  def self.assemble(postgres_resource_id:)
    unless (postgres_resource = PostgresResource[postgres_resource_id])
      fail "No existing postgres resource"
    end

    unless postgres_resource.location.aws?
      fail "PrivateLink is only supported on AWS"
    end

    if postgres_resource.privatelink_aws_resource
      fail "PrivateLink already exists for this postgres resource"
    end

    DB.transaction do
      privatelink = PostgresPrivatelinkAwsResource.create(
        postgres_resource_id: postgres_resource_id
      )
      Strand.create_with_id(privatelink, prog: "Postgres::PostgresPrivatelinkAwsNexus", label: "start")
    end
  end

  def elb_client
    location = postgres_privatelink_aws_resource.location
    Aws::ElasticLoadBalancingV2::Client.new(
      region: location.name,
      credentials: location.location_credential.credentials
    )
  end

  def ec2_client
    postgres_privatelink_aws_resource.location.location_credential.client
  end

  def postgres_resource
    postgres_privatelink_aws_resource.postgres_resource
  end

  def before_run
    when_destroy_set? do
      unless ["destroy", "wait_nlb_deletion"].include?(strand.label)
        hop_destroy
      end
    end
  end

  label def start
    server = postgres_resource.representative_server
    unless server
      fail "No representative server found for postgres resource"
    end

    nic = server.vm.nics.first
    ps = nic.private_subnet

    subnet_id = nic.nic_aws_resource.subnet_id

    # Create Network Load Balancer
    nlb_response = elb_client.create_load_balancer(
      name: "pg-pl-#{postgres_resource.ubid.to_s[..16]}",
      type: "network",
      scheme: "internal",
      ip_address_type: "ipv4",
      subnets: [subnet_id],
      tags: [
        {key: "resource_id", value: postgres_resource.id.to_s},
        {key: "resource_name", value: postgres_resource.name}
      ]
    )

    nlb_arn = nlb_response.load_balancers.first.load_balancer_arn
    postgres_privatelink_aws_resource.update(nlb_arn: nlb_arn)

    hop_wait_nlb_active
  end

  label def wait_nlb_active
    nlb_desc = elb_client.describe_load_balancers(
      load_balancer_arns: [postgres_privatelink_aws_resource.nlb_arn]
    )
    state = nlb_desc.load_balancers.first.state.code

    puts "state: #{state}"
    if state == "active"
      hop_create_target_group
    else
      nap 5
    end
  end

  label def create_target_group
    nic = postgres_resource.representative_server.vm.nics.first
    ps = nic.private_subnet
    vpc_id = ps.private_subnet_aws_resource.vpc_id

    tg_response = elb_client.create_target_group(
      name: "pg-pl-tg-#{postgres_resource.ubid.to_s[..16]}",
      protocol: "TCP",
      port: 5432,
      vpc_id: vpc_id,
      target_type: "ip",
      health_check_protocol: "TCP",
      health_check_port: "5432",
      health_check_interval_seconds: 30,
      healthy_threshold_count: 3,
      unhealthy_threshold_count: 3,
      tags: [
        {key: "resource_id", value: postgres_resource.id.to_s}
      ]
    )

    target_group_arn = tg_response.target_groups.first.target_group_arn
    postgres_privatelink_aws_resource.update(target_group_arn: target_group_arn)

    hop_register_target
  end

  label def register_target
    server = postgres_resource.representative_server
    private_ipv4 = server.vm.nics.first.private_ipv4.network

    elb_client.register_targets(
      target_group_arn: postgres_privatelink_aws_resource.target_group_arn,
      targets: [
        {id: private_ipv4.to_s, port: 5432}
      ]
    )

    hop_create_listener
  end

  label def create_listener
    listener_response = elb_client.create_listener(
      load_balancer_arn: postgres_privatelink_aws_resource.nlb_arn,
      protocol: "TCP",
      port: 5432,
      default_actions: [
        {
          type: "forward",
          target_group_arn: postgres_privatelink_aws_resource.target_group_arn
        }
      ]
    )

    listener_arn = listener_response.listeners.first.listener_arn
    postgres_privatelink_aws_resource.update(listener_arn: listener_arn)

    hop_create_endpoint_service
  end

  label def create_endpoint_service
    endpoint_service_response = ec2_client.create_vpc_endpoint_service_configuration(
      network_load_balancer_arns: [postgres_privatelink_aws_resource.nlb_arn],
      acceptance_required: false,
      tag_specifications: [
        {
          resource_type: "vpc-endpoint-service",
          tags: [
            {key: "Name", value: "pg-pl-#{postgres_resource.ubid.to_s[..16]}"},
            {key: "resource_id", value: postgres_resource.id.to_s}
          ]
        }
      ]
    )

    service_name = endpoint_service_response.service_configuration.service_name
    service_id = endpoint_service_response.service_configuration.service_id

    postgres_privatelink_aws_resource.update(
      service_name: service_name,
      service_id: service_id
    )

    hop_wait
  end

  label def wait
    # Check target health periodically
    when_update_target_set? do
      hop_update_target
    end

    nap 30
  end

  label def update_target
    decr_update_target

    # Deregister old target
    old_targets = elb_client.describe_target_health(
      target_group_arn: postgres_privatelink_aws_resource.target_group_arn
    ).target_health_descriptions

    old_targets.each do |target|
      elb_client.deregister_targets(
        target_group_arn: postgres_privatelink_aws_resource.target_group_arn,
        targets: [{id: target.target.id}]
      )
    end

    # Register new target (current representative server)
    server = postgres_resource.representative_server
    private_ipv4 = server.vm.nics.first.private_ipv4.network

    elb_client.register_targets(
      target_group_arn: postgres_privatelink_aws_resource.target_group_arn,
      targets: [
        {id: private_ipv4.to_s, port: 5432}
      ]
    )

    hop_wait
  end

  label def destroy
    decr_destroy

    # Delete VPC Endpoint Service
    if postgres_privatelink_aws_resource.service_id
      ec2_client.delete_vpc_endpoint_service_configurations(
        service_ids: [postgres_privatelink_aws_resource.service_id]
      )
    end

    # Delete Listener
    if postgres_privatelink_aws_resource.listener_arn
      elb_client.delete_listener(
        listener_arn: postgres_privatelink_aws_resource.listener_arn
      )
    end

    # Deregister targets
    if postgres_privatelink_aws_resource.target_group_arn
      targets = elb_client.describe_target_health(
        target_group_arn: postgres_privatelink_aws_resource.target_group_arn
      ).target_health_descriptions

      targets.each do |target|
        elb_client.deregister_targets(
          target_group_arn: postgres_privatelink_aws_resource.target_group_arn,
          targets: [{id: target.target.id}]
        )
      end

      # Delete Target Group
      elb_client.delete_target_group(
        target_group_arn: postgres_privatelink_aws_resource.target_group_arn
      )
    end

    # Delete Load Balancer
    if postgres_privatelink_aws_resource.nlb_arn
      elb_client.delete_load_balancer(
        load_balancer_arn: postgres_privatelink_aws_resource.nlb_arn
      )
    end

    hop_wait_nlb_deletion
  end

  label def wait_nlb_deletion
    # Wait for NLB to be fully deleted before destroying the record
    if postgres_privatelink_aws_resource.nlb_arn
      begin
        nlb_desc = elb_client.describe_load_balancers(
          load_balancer_arns: [postgres_privatelink_aws_resource.nlb_arn]
        )
        # NLB still exists, wait
        nap 10
      rescue Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound
        # NLB is deleted, we can proceed
        postgres_privatelink_aws_resource.destroy
        pop "PrivateLink deleted"
      end
    else
      postgres_privatelink_aws_resource.destroy
      pop "PrivateLink deleted"
    end
  end
end
