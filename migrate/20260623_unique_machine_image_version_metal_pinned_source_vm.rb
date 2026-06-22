# frozen_string_literal: true

Sequel.migration do
  no_transaction
  change do
    # At most one in-flight archive per source VM. The lifecycle
    # invariant on pinned_source_vm_id (non-NULL iff a capture is actively
    # in flight from that VM) means this index naturally allows
    # multiple completed/failed versions per VM while preventing two
    # concurrent captures from the same VM.
    add_index :machine_image_version_metal, :pinned_source_vm_id, unique: true, concurrently: true, where: Sequel.~(pinned_source_vm_id: nil)
  end
end
