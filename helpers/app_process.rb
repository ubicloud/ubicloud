# frozen_string_literal: true

class Clover
  def app_process_list
    dataset = dataset_authorize(@project.app_processes_dataset, "AppProcess:view").eager(:location, :private_subnet)
    dataset = dataset.where(location_id: @location.id) if @location

    if api?
      paginated_result(dataset, Serializers::AppProcess)
    else
      @app_processes = dataset.all
      view "app/index"
    end
  end

  def app_process_post(name)
    authorize("AppProcess:create", @project)

    group_name = typecast_params.nonempty_str("group_name")
    vm_size = typecast_params.nonempty_str("vm_size")
    subnet_name = typecast_params.nonempty_str("subnet_name")
    lb_name = typecast_params.nonempty_str("lb_name")
    src_port = typecast_params.pos_int("src_port")
    dst_port = typecast_params.pos_int("dst_port")

    # Derive group_name from name if not provided: "mastodon-web" => group "mastodon", process "web"
    if group_name
      process_name = name.delete_prefix("#{group_name}-")
      process_name = name if process_name == name && name != group_name
    else
      parts = name.split("-", 2)
      if parts.length == 2
        group_name = parts[0]
        process_name = parts[1]
      else
        group_name = name
        process_name = name
      end
    end

    # Resolve or create subnet
    ps = nil
    if subnet_name
      ps = authorized_private_subnet(location_id: @location.id, name: subnet_name)
      fail Validation::ValidationFailed.new("subnet_name" => "Private subnet '#{subnet_name}' not found") unless ps
    end

    # Resolve existing LB
    lb = nil
    if lb_name
      lb = authorized_object(association: :load_balancers, key: "lb_id", perm: "LoadBalancer:view", name: lb_name,
        ds: @project.load_balancers_dataset.where(private_subnet_id: PrivateSubnet.where(location_id: @location.id).select(:id)))
      fail Validation::ValidationFailed.new("lb_name" => "Load balancer '#{lb_name}' not found") unless lb
    elsif src_port && dst_port && ps
      # Create a new LB if port mapping given
      lb_auto_name = "#{name}-lb"
      lb = Prog::Vnet::LoadBalancerNexus.assemble(
        ps.id,
        name: lb_auto_name,
        src_port: Validation.validate_port(:src_port, src_port),
        dst_port: Validation.validate_port(:dst_port, dst_port)
      ).subject
    end

    ap = AppProcess.create(
      group_name: group_name,
      name: process_name,
      project_id: @project.id,
      location_id: @location.id,
      vm_size: vm_size,
      private_subnet_id: ps&.id
    )
    audit_log(ap, "create")

    if api?
      Serializers::AppProcess.serialize(ap, {detailed: true})
    else
      flash["notice"] = "'#{name}' created"
      request.redirect ap
    end
  end

  # Add VMs to an app process.
  # With vm_names: claim existing VMs into the process type.
  # Without vm_names: create a new VM (requires deployment_managed).
  # Increments desired_count.
  def app_process_add(ap)
    authorize("AppProcess:edit", ap)
    vm_names = typecast_params.array(:nonempty_str, "vm_names")

    if vm_names && !vm_names.empty?
      # Claim existing VMs
      added = []
      DB.transaction do
        vm_names.each do |vm_name|
          vm = dataset_authorize(@project.vms_dataset, "Vm:view").first(name: vm_name, location_id: ap.location_id)
          fail Validation::ValidationFailed.new("vm_names" => "VM '#{vm_name}' not found in #{ap.display_location}") unless vm

          # Check VM isn't already a member of any app process
          existing = AppProcessMember.first(vm_id: vm.id)
          if existing
            fail Validation::ValidationFailed.new("vm_names" => "VM '#{vm_name}' is already a member of #{existing.app_process.display_name}")
          end

          # Check VM is on the process type's subnet (if one is set)
          if ap.private_subnet_id
            vm_subnet_ids = vm.nics.map(&:private_subnet_id)
            unless vm_subnet_ids.include?(ap.private_subnet_id)
              fail Validation::ValidationFailed.new("vm_names" => "VM '#{vm_name}' is not on subnet '#{ap.private_subnet.name}'")
            end
          end

          member = AppProcessMember.create(
            app_process_id: ap.id,
            vm_id: vm.id,
            ordinal: ap.next_ordinal,
            state: "active"
          )

          # Copy init tags from process type to member
          ap.app_process_inits.each do |api|
            AppMemberInit.create(
              app_process_member_id: member.id,
              init_script_tag_id: api.init_script_tag_id
            )
          end

          # If the process has an LB, add the VM to the LB
          lb = ap.load_balancer
          if lb
            lb_vm = LoadBalancerVm.first(load_balancer_id: lb.id, vm_id: vm.id)
            unless lb_vm
              lb.add_vm(vm)
            end
          end

          added << member
        end

        # Increment desired_count
        ap.update(desired_count: ap.desired_count + vm_names.size)
      end

      audit_log(ap, "add_member")
      Serializers::AppProcess.serialize(ap.reload, {detailed: true})
    else
      # Create new VM — requires deployment_managed
      fail Validation::ValidationFailed.new("vm_names" => "UMI must be set to create new VMs. Use 'set --umi' first, or provide VM names to claim existing VMs.") unless ap.deployment_managed?
      fail Validation::ValidationFailed.new("vm_names" => "Subnet must be set to create new VMs") unless ap.private_subnet_id
      fail Validation::ValidationFailed.new("vm_names" => "VM size must be set to create new VMs. Use 'set --size' or create with '--size'.") unless ap.vm_size

      ordinal = ap.next_ordinal
      vm_name = "#{ap.flat_name}-#{ordinal}"

      # Compose init script from process type's init tags
      init_tags = ap.app_process_inits_dataset.order(:ordinal).all
      combined_init = init_tags.map { |api| api.init_script_tag.init_script }.join("\n") if init_tags.any?

      DB.transaction do
        st = Prog::Vm::Nexus.assemble_with_sshable(
          @project.id,
          name: vm_name,
          size: ap.vm_size,
          location_id: ap.location_id,
          private_subnet_id: ap.private_subnet_id,
          boot_image: "ubuntu-noble",
          enable_ip4: false,
          init_script: combined_init
        )
        vm = st.subject

        member = AppProcessMember.create(
          app_process_id: ap.id,
          vm_id: vm.id,
          ordinal: ordinal,
          state: "active"
        )

        # Copy init tags from process type to member
        init_tags.each do |api|
          AppMemberInit.create(
            app_process_member_id: member.id,
            init_script_tag_id: api.init_script_tag_id
          )
        end

        # Add to LB if present
        lb = ap.load_balancer
        lb&.add_vm(vm)

        # Increment desired_count
        ap.update(desired_count: ap.desired_count + 1)
      end

      audit_log(ap, "add_member")
      Serializers::AppProcess.serialize(ap.reload, {detailed: true})
    end
  end

  # Detach VMs from an app process. The VMs keep running but are no
  # longer managed by the app. desired_count is NOT changed — homeostasis
  # will create a replacement (actual < desired).
  def app_process_detach(ap)
    authorize("AppProcess:edit", ap)
    vm_name = typecast_params.nonempty_str!("vm_name")

    member = ap.app_process_members_dataset.join(:vm, id: :vm_id).where(Sequel[:vm][:name] => vm_name).select_all(:app_process_member).first
    fail Validation::ValidationFailed.new("vm_name" => "VM '#{vm_name}' is not a member of #{ap.display_name}") unless member

    DB.transaction do
      # Remove from LB if present
      lb = ap.load_balancer
      if lb
        vm = Vm[member.vm_id]
        lb_vm = LoadBalancerVm.first(load_balancer_id: lb.id, vm_id: vm.id)
        if lb_vm
          lb.detach_vm(vm)
        end
      end

      # Destroy member (app_member_init records cascade via FK)
      member.destroy
      # desired_count unchanged — actual < desired triggers regrow
    end

    audit_log(ap, "remove_member")
    Serializers::AppProcess.serialize(ap.reload, {detailed: true})
  end

  # Remove (destroy) a VM from an app process. Decrements desired_count.
  def app_process_remove(ap)
    authorize("AppProcess:edit", ap)
    vm_name = typecast_params.nonempty_str!("vm_name")

    member = ap.app_process_members_dataset.join(:vm, id: :vm_id).where(Sequel[:vm][:name] => vm_name).select_all(:app_process_member).first
    fail Validation::ValidationFailed.new("vm_name" => "VM '#{vm_name}' is not a member of #{ap.display_name}") unless member

    vm = Vm[member.vm_id]
    fail Validation::ValidationFailed.new("vm_name" => "VM '#{vm_name}' not found") unless vm

    authorize("Vm:delete", vm)

    DB.transaction do
      # Remove from LB if present
      lb = ap.load_balancer
      if lb
        lb_vm = LoadBalancerVm.first(load_balancer_id: lb.id, vm_id: vm.id)
        if lb_vm
          lb.remove_vm(vm)
        end
      end

      member.destroy
      vm.incr_destroy

      # Decrement desired_count — no regrow
      ap.update(desired_count: [ap.desired_count - 1, 0].max)
    end

    audit_log(ap, "remove_member")
    Serializers::AppProcess.serialize(ap.reload, {detailed: true})
  end

  # Set image, init scripts, and/or VM size on an app process type.
  # Supports:
  #   --umi ref          Set UMI reference
  #   --init name@ver    Reference existing init script tag
  #   --init name=content  Push content to registry, then reference
  #   --size size        Set VM size
  #   --from vN          Re-release from release N
  #   --keep name        Keep current version of named init when using --from
  def app_process_set(ap)
    authorize("AppProcess:edit", ap)
    umi = typecast_params.nonempty_str("umi")
    vm_size = typecast_params.nonempty_str("vm_size")
    init_refs = typecast_params.array(:nonempty_str, "init")
    from_version = typecast_params.nonempty_str("from")
    keep_names = typecast_params.array(:nonempty_str, "keep")

    unless umi || vm_size || init_refs || from_version
      fail Validation::ValidationFailed.new("umi" => "At least one of --umi, --init, --size, or --from must be provided")
    end

    if keep_names && !from_version
      fail Validation::ValidationFailed.new("keep" => "--keep can only be used with --from")
    end

    push_results = []
    resolved_tag_ids = {} # name => init_script_tag_id

    DB.transaction do
      updates = {}

      if umi
        updates[:umi_id] = SecureRandom.uuid
        updates[:umi_ref] = umi
      end

      updates[:vm_size] = vm_size if vm_size

      # Handle --from vN: load template from a previous release
      if from_version
        release_num = from_version.delete_prefix("v").to_i
        fail Validation::ValidationFailed.new("from" => "Invalid release version: #{from_version}") if release_num <= 0

        release = AppRelease.where(
          project_id: ap.project_id,
          group_name: ap.group_name,
          release_number: release_num
        ).first
        fail Validation::ValidationFailed.new("from" => "Release v#{release_num} not found") unless release

        # Find snapshot for this process type
        snapshot = release.app_release_snapshots_dataset
          .where(app_process_id: ap.id)
          .first
        fail Validation::ValidationFailed.new("from" => "Release v#{release_num} has no snapshot for #{ap.flat_name}") unless snapshot

        # Restore UMI from snapshot (unless --umi explicitly provided)
        unless umi
          updates[:umi_id] = snapshot.umi_id
          updates[:umi_ref] = AppProcess.where(id: ap.id).get(:umi_ref)
          # Look up umi_ref from the snapshot's process state at that time
          # For now, keep current umi_ref if restoring from snapshot
        end

        # Restore init tags from snapshot
        snapshot_inits = snapshot.app_release_snapshot_inits
        keep_set = (keep_names || []).to_set

        snapshot_inits.each do |si|
          tag = si.init_script_tag
          unless keep_set.include?(tag.name)
            resolved_tag_ids[tag.name] = tag.id
          end
        end

        # For kept inits, preserve current version
        if keep_names
          current_inits = ap.app_process_inits_dataset.all
          keep_names.each do |keep_name|
            current_init = current_inits.find { |ci| ci.init_script_tag.name == keep_name }
            if current_init
              resolved_tag_ids[keep_name] = current_init.init_script_tag_id
            end
            # If not found in current inits, just skip (no error)
          end
        end
      end

      # Handle --init refs: resolve each to an init_script_tag
      if init_refs
        init_refs.each do |ref|
          if ref.include?("=")
            # Push-and-set: name=content
            name, content = ref.split("=", 2)
            Validation.validate_name(name)

            if content.bytesize > 2000
              fail Validation::ValidationFailed.new("init" => "Init script '#{name}' must be 2000 bytes or less")
            end

            # Find latest version for this name
            latest = @project.init_script_tags_dataset
              .where(name: name)
              .order(Sequel.desc(:version))
              .first

            if latest && latest.init_script == content
              # Content matches — reuse existing
              resolved_tag_ids[name] = latest.id
              push_results << {name: name, version: latest.version, unchanged: true}
            else
              # Create new version
              new_version = latest ? latest.version + 1 : 1
              tag = InitScriptTag.create(
                project_id: @project.id,
                name: name,
                version: new_version,
                init_script: content
              )
              resolved_tag_ids[name] = tag.id
              push_results << {name: name, version: new_version, unchanged: false}
            end
          elsif ref.include?("@")
            # Reference existing: name@version
            tag_name, version_str = ref.split("@", 2)
            version = Integer(version_str, exception: false)
            fail Validation::ValidationFailed.new("init" => "Invalid version in '#{ref}'") unless version

            tag = @project.init_script_tags_dataset.first(name: tag_name, version: version)
            fail Validation::ValidationFailed.new("init" => "Init script '#{ref}' not found") unless tag

            resolved_tag_ids[tag_name] = tag.id
          else
            fail Validation::ValidationFailed.new("init" => "Invalid init ref '#{ref}'. Use name@version or name=content")
          end
        end
      end

      # Apply UMI/size updates
      ap.update(**updates) unless updates.empty?

      # Update app_process_init records if any init changes
      unless resolved_tag_ids.empty?
        # Merge with existing inits: resolved_tag_ids overrides, others stay
        current_inits = ap.app_process_inits_dataset.eager(:init_script_tag).all
        current_by_name = {}
        current_inits.each { |ci| current_by_name[ci.init_script_tag.name] = ci }

        # If --from was used without --init, replace ALL inits with snapshot
        # If --init was used, merge: update named inits, keep others
        if from_version && !init_refs
          # Full replacement from snapshot
          ap.app_process_inits_dataset.destroy
          ordinal = 0
          resolved_tag_ids.each do |_name, tag_id|
            AppProcessInit.create(
              app_process_id: ap.id,
              init_script_tag_id: tag_id,
              ordinal: ordinal
            )
            ordinal += 1
          end
        else
          # Partial update: update/add named inits, keep others
          resolved_tag_ids.each do |name, tag_id|
            existing = current_by_name[name]
            if existing
              if existing.init_script_tag_id != tag_id
                existing.update(init_script_tag_id: tag_id)
              end
            else
              # New init — assign next ordinal
              max_ordinal = ap.app_process_inits_dataset.max(:ordinal) || -1
              AppProcessInit.create(
                app_process_id: ap.id,
                init_script_tag_id: tag_id,
                ordinal: max_ordinal + 1
              )
            end
          end
        end
      end

      # Create release if template changed (umi or init)
      if umi || !resolved_tag_ids.empty?
        create_app_release(ap)
      end
    end

    audit_log(ap, "update")
    result = Serializers::AppProcess.serialize(ap.reload, {detailed: true})
    result[:push_results] = push_results unless push_results.empty?
    result
  end

  # Scale: set desired_count to N.
  # If N > current: creates (N - current) VMs from template.
  # If N < current: error — operator must explicitly remove specific VMs.
  # Refuses when fleet is heterogeneous.
  def app_process_scale(ap)
    authorize("AppProcess:edit", ap)
    count = typecast_params.pos_int!("count")

    fail Validation::ValidationFailed.new("count" => "Scale count must be positive") unless count > 0

    current = ap.app_process_members_dataset.count

    if count < current
      fail Validation::ValidationFailed.new("count" => "Cannot scale down from #{current} to #{count}. Use 'remove' to explicitly remove specific VMs.")
    end

    # Check fleet homogeneity when scaling up with existing members
    if count > current && current > 0
      check_fleet_homogeneous(ap)
    end

    # For scaling up, we need deployment_managed + subnet + size
    if count > current
      fail Validation::ValidationFailed.new("count" => "UMI must be set to scale up. Use 'set --umi' first.") unless ap.deployment_managed?
      fail Validation::ValidationFailed.new("count" => "Subnet must be set to scale up") unless ap.private_subnet_id
      fail Validation::ValidationFailed.new("count" => "VM size must be set to scale up. Use 'set --size' or create with '--size'.") unless ap.vm_size
    end

    DB.transaction do
      ap.update(desired_count: count)

      # Create (count - current) new VMs
      to_create = count - current
      init_tags = ap.app_process_inits_dataset.order(:ordinal).all
      combined_init = init_tags.map { |api| api.init_script_tag.init_script }.join("\n") if init_tags.any?
      lb = ap.load_balancer

      to_create.times do
        ordinal = ap.next_ordinal
        vm_name = "#{ap.flat_name}-#{ordinal}"

        st = Prog::Vm::Nexus.assemble_with_sshable(
          ap.project_id,
          name: vm_name,
          size: ap.vm_size,
          location_id: ap.location_id,
          private_subnet_id: ap.private_subnet_id,
          boot_image: "ubuntu-noble",
          enable_ip4: false,
          init_script: combined_init
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

    audit_log(ap, "update")
    Serializers::AppProcess.serialize(ap.reload, {detailed: true})
  end

  # Show release history for the app group.
  def app_process_releases(ap)
    authorize("AppProcess:view", ap)

    releases = AppRelease.where(project_id: ap.project_id, group_name: ap.group_name)
      .order(Sequel.desc(:release_number))
      .eager(app_release_snapshots: [:app_process, {app_release_snapshot_inits: :init_script_tag}])
      .all

    # Build process name lookup for group
    group_process_names = ap.group_processes.map(&:name).sort

    items = releases.map do |rel|
      # Find the snapshot for the changed process type
      changed_snapshot = rel.app_release_snapshots.find { |s| s.app_process.name == rel.process_name }

      # Determine process label: "all" if all processes share this snapshot's template,
      # otherwise the changed process name
      process_label = if group_process_names.size <= 1
        rel.process_name
      else
        rel.process_name
      end

      # Get umi_ref from the snapshot's associated process
      umi_ref = changed_snapshot&.app_process&.umi_ref

      # Get init script tags from the changed process's snapshot
      init_tags = (changed_snapshot&.app_release_snapshot_inits || []).map do |si|
        tag = si.init_script_tag
        {name: tag.name, version: tag.version, ref: tag.ref}
      end

      {
        release_number: rel.release_number,
        created_at: rel.created_at.iso8601,
        process_name: process_label,
        action: rel.action,
        umi_ref: umi_ref,
        init_tags: init_tags
      }
    end

    {items: items}
  end

  private

  # Create a new app release with snapshots for all processes in the group.
  # Each snapshot captures the full state (UMI + init script tags).
  def create_app_release(ap)
    next_num = (ap.latest_release_number || 0) + 1

    release = AppRelease.create(
      project_id: ap.project_id,
      group_name: ap.group_name,
      release_number: next_num,
      process_name: ap.name,
      action: "set"
    )

    # Create snapshot for each process in the group
    ap.group_processes.each do |proc|
      deploy_ordinal = proc.app_release_snapshots_dataset.count

      snapshot = AppReleaseSnapshot.create(
        app_release_id: release.id,
        app_process_id: proc.id,
        deploy_ordinal: deploy_ordinal,
        umi_id: proc.umi_id
      )

      # Snapshot all init script tags
      proc.app_process_inits_dataset.order(:ordinal).each do |api|
        AppReleaseSnapshotInit.create(
          app_release_snapshot_id: snapshot.id,
          init_script_tag_id: api.init_script_tag_id
        )
      end
    end

    release
  end

  # Check that all members match the process type's current init template.
  # Raises ValidationFailed if fleet is heterogeneous.
  def check_fleet_homogeneous(ap)
    template_init_tag_ids = ap.app_process_inits_dataset.order(:ordinal).select_map(:init_script_tag_id).sort

    mismatched = []
    ap.app_process_members.each do |m|
      member_init_tag_ids = m.app_member_inits.map(&:init_script_tag_id).sort
      mismatched << m unless member_init_tag_ids == template_init_tag_ids
    end

    if mismatched.any?
      total = ap.app_process_members.count
      on_template = total - mismatched.count
      msg = "#{ap.flat_name}: fleet is mixed, scale target is ambiguous\n\n"
      msg += "  #{on_template} VM#{"s" if on_template != 1} on current template\n"
      msg += "  #{mismatched.count} VM#{"s" if mismatched.count != 1} on different init scripts\n\n"
      msg += "Resolve the mismatch before scaling."
      fail Validation::ValidationFailed.new("count" => msg)
    end
  end
end
