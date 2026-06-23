# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:machine_image_version_metal) do
      # Records the VM a metal machine image version is currently being captured
      # from. Used to prevent start, destroy, and concurrent capture of the
      # source VM while the capture is in progress.
      add_foreign_key :pinned_source_vm_id, :vm, type: :uuid, unique: true
    end
  end
end
