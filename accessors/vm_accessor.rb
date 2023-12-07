# frozen_string_literal: true

module VmAccessor
  def project_vm_get(project, current_user)
    serializer = Serializers::Web::Vm
    serializer.serialize(project.vms_dataset.authorized(current_user.id, "Vm:view").eager(:semaphores, :assigned_vm_address, :vm_storage_volumes).order(Sequel.desc(:created_at)).all)
  end

  def project_vm_post(project, params)
    puts params
    _ = Prog::Vm::Nexus.assemble(
      params["public-key"],
      project.id,
      name: params["name"],
      unix_user: params["user"],
      size: params["size"],
      location: params["location"],
      boot_image: params["boot-image"],
      private_subnet_id: params["ps_id"],
      enable_ip4: params.key?("enable-ip4")
    )
  end
end
