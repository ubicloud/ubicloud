# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:machine_image_version_metal) do
      # Records the VM a metal machine image version was captured from,
      # so the VM nexus can refuse destroy/start while a capture from it
      # is in flight. Null for versions sourced from a URL, and nulled
      # out when the VM is later destroyed (the historical pointer isn't
      # worth blocking VM destruction over).
      add_foreign_key :source_vm_id, :vm, type: :uuid, on_delete: :set_null
    end
  end
end
