# frozen_string_literal: true

class Prog::Aws::UpdateFirewallRules < Prog::Base
  subject_is :vm

  def before_run
    pop "firewall rule is added" if vm.destroy_set?
  end

  label def update_firewall_rules
    rules = vm.firewalls.map(&:firewall_rules).flatten

    client.update_security_group_rules(
      group_id: vm.security_group_id,
      ip_permissions: [
        {
          ip_protocol: "tcp",
          from_port: 0,
          to_port: 65535,
          ip_ranges: [
            {cidr_ip: "0.0.0.0/0"}
          ]
        }
      ]
    )
    pop "firewall rule is added"
  end

  def access_key
    vm.private_subnet_aws_resource.customer_aws_account.aws_account_access_key
  end

  def secret_key
    vm.private_subnet_aws_resource.customer_aws_account.aws_account_secret_access_key
  end

  def region
    vm.private_subnet_aws_resource.customer_aws_account.location
  end

  def client
    @client ||= Aws::EC2::Client.new(access_key_id: access_key, secret_access_key: secret_key, region: region)
  end
end
