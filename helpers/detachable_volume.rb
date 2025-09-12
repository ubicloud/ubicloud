# frozen_string_literal: true

class Clover
  def detachable_volume_list_dataset
    dataset_authorize(@project.detachable_volumes_dataset, "DetachableVolume:view")
  end

  def detachable_volume_post(name, size_gib)
    authorize("DetachableVolume:create", @project.id)
    dv = nil
    DB.transaction do
      dv = Prog::Storage::DetachableVolumeNexus.assemble(name, @project, size_gib).subject
      audit_log(dv, "create")
    end
    if api?
      Serializers::DetachableVolume.serialize(dv)
    else
      flash["notice"] = "'#{name}' will be ready in a few minutes"
      request.redirect dv
    end
  end
end
