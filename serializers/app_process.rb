# frozen_string_literal: true

class Serializers::AppProcess < Serializers::Base
  def self.serialize_internal(ap, options = {})
    base = {
      id: ap.ubid,
      name: ap.flat_name,
      group_name: ap.group_name,
      process_name: ap.name,
      location: ap.display_location,
      vm_size: ap.vm_size,
      desired_count: ap.desired_count,
      subnet: ap.private_subnet&.name
    }

    if options[:detailed]
      base[:deployment_managed] = ap.deployment_managed?
      base[:umi_ref] = ap.umi_ref
      base[:connected_subnets] = ap.external_connected_subnet_names

      # Init script tags on the process type (template)
      base[:init_tags] = ap.app_process_inits_dataset.order(:ordinal).all.map do |api|
        tag = api.init_script_tag
        {name: tag.name, version: tag.version, ref: tag.ref}
      end

      # Find LB for this process type's subnet by checking member VMs
      lb = nil
      member_vm_ids = ap.app_process_members.map(&:vm_id)
      if ap.private_subnet_id && member_vm_ids.any?
        lb_vm = LoadBalancerVm.where(vm_id: member_vm_ids).first
        lb = LoadBalancer[lb_vm.load_balancer_id] if lb_vm
      end
      # Also check subnet-level: LBs whose private_subnet matches
      lb ||= LoadBalancer.first(private_subnet_id: ap.private_subnet_id) if ap.private_subnet_id
      base[:lb_name] = lb&.name

      # Build per-VM health lookup from LB
      lb_health = {}
      if lb
        LoadBalancerVm.where(load_balancer_id: lb.id).each do |lbv|
          ports = LoadBalancerVmPort.where(load_balancer_vm_id: lbv.id).all
          if ports.any? { |p| p.state == "evacuating" }
            lb_health[lbv.vm_id] = "drained"
          elsif ports.any? { |p| p.state == "up" }
            lb_health[lbv.vm_id] = "healthy"
          else
            lb_health[lbv.vm_id] = "unhealthy"
          end
        end
      end

      base[:members] = ap.app_process_members.map do |m|
        vm = m.vm
        member = {
          id: m.ubid,
          vm_name: vm&.name,
          state: m.state,
          ordinal: m.ordinal,
          created_at: vm&.created_at&.iso8601,
          boot_image: vm&.boot_image
        }

        # Per-VM LB health
        if lb && vm
          member[:lb_health] = lb_health[vm.id]
        end

        # Per-VM health (VM state)
        member[:healthy] = m.state == "active" && vm&.display_state == "running"

        # Per-VM init script tags from app_member_init
        member[:init_tags] = m.app_member_inits.map do |ami|
          tag = ami.init_script_tag
          {name: tag.name, version: tag.version, ref: tag.ref}
        end

        member
      end

      # Alien VMs: on the subnet but not members of this process type
      if ap.private_subnet_id
        alien_vms = Vm.where(
          Sequel[:vm][:id] => Nic.where(private_subnet_id: ap.private_subnet_id).select(:vm_id)
        ).exclude(
          Sequel[:vm][:id] => ap.app_process_members_dataset.select(:vm_id)
        ).all

        base[:aliens] = alien_vms.map do |vm|
          alien = {
            vm_name: vm.name,
            created_at: vm.created_at&.iso8601,
            boot_image: vm.boot_image,
            healthy: vm.display_state == "running"
          }

          # Check if the alien has member init tags from another process
          other_member = AppProcessMember.first(vm_id: vm.id)
          if other_member
            alien[:init_tags] = other_member.app_member_inits.map do |ami|
              tag = ami.init_script_tag
              {name: tag.name, version: tag.version, ref: tag.ref}
            end
          else
            alien[:init_tags] = []
          end

          alien
        end
      else
        base[:aliens] = []
      end

      # Empty slots: desired - actual
      actual = ap.app_process_members_dataset.count
      base[:empty_slots] = [ap.desired_count - actual, 0].max

      # Latest release number for this process type's group
      base[:release_number] = ap.latest_release_number
    end

    if options[:group_status]
      processes = ap.group_processes
      release_num = ap.latest_release_number
      base[:release_number] = release_num
      base[:processes] = processes.map { |p| serialize_internal(p, detailed: true) }
    end

    base
  end
end
