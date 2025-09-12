# frozen_string_literal: true

class Prog::Storage::DetachableVolumeNexus < Prog::Base
  subject_is :detachable_volume

  def self.assemble(name, project, size_gib)
    detachable_volume = DetachableVolume.create(
      name: name,
      project_id: project.id,
      size_gib: size_gib
    )

    Strand.create_with_id(detachable_volume.id, prog: "Storage::DetachableVolumeNexus", label: "wait")
  end

  def before_run
    when_destroy_set? do
      hop_destroy if strand.label != "destroy"
    end
  end

  label def wait
    nap 10
  end

  label def destroy
    detachable_volume.destroy
    pop "detachable volume destroyed"
  end
end
