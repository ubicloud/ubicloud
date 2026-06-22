# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:machine_image_version_metal) do
      # Records the VM a metal machine image version is currently being
      # captured from. Set when .assemble_from_vm creates the row, cleared
      # when the capture finishes (success or failure), so the VM nexus
      # can refuse destroy/start against any VM with a non-NULL row by a
      # plain query. NULL for versions sourced from a URL.
      add_foreign_key :pinned_source_vm_id, :vm, type: :uuid, on_delete: :set_null
    end
  end
end
