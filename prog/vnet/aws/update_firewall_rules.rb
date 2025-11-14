# frozen_string_literal: true

class Prog::Vnet::Aws::UpdateFirewallRules < Prog::Base
  subject_is :vm

  def before_run
    pop "firewall rule is added" if vm.destroy_set?
  end

  label def update_firewall_rules
    rules = vm.firewalls.flat_map(&:firewall_rules)
    permissions = rules.select(&:port_range).map! do |rule|
      perm = {
        ip_protocol: "tcp",
        from_port: rule.port_range.begin,
        to_port: rule.port_range.end - 1
      }
      if rule.ip6?
        perm[:ipv_6_ranges] = [{cidr_ipv_6: rule.cidr.to_s}]
      else
        perm[:ip_ranges] = [{cidr_ip: rule.cidr.to_s}]
      end
      perm
    end

    permissions.each do |perm|
      aws_client.authorize_security_group_ingress({
        group_id: vm.private_subnets.first.private_subnet_aws_resource.security_group_id,
        ip_permissions: [perm]
      })
    rescue Aws::EC2::Errors::InvalidPermissionDuplicate
      next
    end

    hop_remove_aws_old_rules
  end

  label def remove_aws_old_rules
    rules = vm.firewalls.map(&:firewall_rules).flatten
    ip4_rules = rules.select { !it.ip6? && it.port_range }
    ip6_rules = rules.select { it.ip6? && it.port_range }

    # Fetch existing security group rules
    security_group = aws_client.describe_security_groups({
      group_ids: [vm.private_subnets.first.private_subnet_aws_resource.security_group_id]
    }).security_groups.first

    # Remove existing rules that aren't in our current rules list
    permissions_to_revoke = security_group.ip_permissions.filter_map do |permission|
      next unless permission.ip_protocol == "tcp"

      ip_ranges_to_revoke = permission.ip_ranges.select do |ip_range|
        ip4_rules.none? { |r| r.cidr.to_s == ip_range.cidr_ip && r.port_range.begin == permission.from_port && r.port_range.end - 1 == permission.to_port }
      end

      ipv_6_ranges_to_revoke = permission.ipv_6_ranges.select do |ip_range|
        ip6_rules.none? { |r| r.cidr.to_s == ip_range.cidr_ipv_6 && r.port_range.begin == permission.from_port && r.port_range.end - 1 == permission.to_port }
      end

      next if ip_ranges_to_revoke.empty? && ipv_6_ranges_to_revoke.empty?

      perm = {
        ip_protocol: "tcp",
        from_port: permission.from_port,
        to_port: permission.to_port
      }
      perm[:ip_ranges] = ip_ranges_to_revoke if ip_ranges_to_revoke.any?
      perm[:ipv_6_ranges] = ipv_6_ranges_to_revoke if ipv_6_ranges_to_revoke.any?
      perm
    end

    if permissions_to_revoke.any?
      permissions_to_revoke.each do |perm|
        aws_client.revoke_security_group_ingress({
          group_id: vm.private_subnets.first.private_subnet_aws_resource.security_group_id,
          ip_permissions: [perm]
        })
      rescue Aws::EC2::Errors::InvalidPermissionNotFound
        next
      end
    end

    pop "firewall rule is added"
  end

  def aws_client
    @aws_client ||= vm.location.location_credential.client
  end
end
