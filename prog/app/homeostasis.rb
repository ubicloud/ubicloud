# frozen_string_literal: true

class Prog::App::Homeostasis < Prog::Base
  label def check
    # Find app processes where actual member count < desired_count
    # and the template is complete (umi_ref set, so we know what to deploy)
    AppProcess.where(Sequel.lit(
      "desired_count > 0 AND umi_ref IS NOT NULL AND private_subnet_id IS NOT NULL AND vm_size IS NOT NULL"
    )).each do |ap|
      actual = ap.app_process_members_dataset.count
      gap = ap.desired_count - actual
      next unless gap > 0

      fill_gap(ap, gap)
    end

    nap 60
  end

  private

  def fill_gap(ap, count)
    init_tags = ap.app_process_inits_dataset.order(:ordinal).all
    combined_init = init_tags.map { |api| api.init_script_tag.init_script }.join("\n") if init_tags.any?
    lb = ap.load_balancer

    # Resolve UMI reference to storage_volumes when umi_ref is set
    vm_options = if ap.umi_ref
      mi = MachineImage.first(project_id: ap.project_id, location_id: ap.location_id, name: ap.umi_ref)
      fail "Machine image not found: #{ap.umi_ref}" unless mi
      miv = mi.active_version
      fail "No active version for machine image: #{ap.umi_ref}" unless miv
      {storage_volumes: [{machine_image_version_id: miv.id, size_gib: miv.size_gib}]}
    else
      {boot_image: "ubuntu-noble"}
    end

    count.times do
      ordinal = ap.next_ordinal
      vm_name = "#{ap.flat_name}-#{ordinal}"

      st = Prog::Vm::Nexus.assemble_with_sshable(
        ap.project_id,
        name: vm_name,
        size: ap.vm_size,
        location_id: ap.location_id,
        private_subnet_id: ap.private_subnet_id,
        enable_ip4: true,
        init_script: combined_init,
        **vm_options
      )
      vm = st.subject

      member = AppProcessMember.create(
        app_process_id: ap.id,
        vm_id: vm.id,
        ordinal: ordinal,
        state: "active"
      )

      init_tags.each do |api|
        AppMemberInit.create(
          app_process_member_id: member.id,
          init_script_tag_id: api.init_script_tag_id
        )
      end

      lb&.add_vm(vm)
    end
  end
end
