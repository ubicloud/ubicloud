# frozen_string_literal: true

Sequel.migration do
  up do
    # Add ON DELETE CASCADE to app_process_member.vm_id so that when a VM
    # is deleted (ubi vm delete, host failure), the member record is
    # automatically removed. desired_count stays unchanged → homeostasis regrows.
    alter_table(:app_process_member) do
      drop_foreign_key [:vm_id], name: :app_process_member_vm_id_fkey
      add_foreign_key [:vm_id], :vm, name: :app_process_member_vm_id_fkey, on_delete: :cascade
    end

    # Add ON DELETE CASCADE to app_member_init.app_process_member_id so
    # that member init records are cleaned up when the member is removed.
    alter_table(:app_member_init) do
      drop_foreign_key [:app_process_member_id], name: :app_member_init_app_process_member_id_fkey
      add_foreign_key [:app_process_member_id], :app_process_member, name: :app_member_init_app_process_member_id_fkey, on_delete: :cascade
    end
  end

  down do
    alter_table(:app_member_init) do
      drop_foreign_key [:app_process_member_id], name: :app_member_init_app_process_member_id_fkey
      add_foreign_key [:app_process_member_id], :app_process_member, name: :app_member_init_app_process_member_id_fkey
    end

    alter_table(:app_process_member) do
      drop_foreign_key [:vm_id], name: :app_process_member_vm_id_fkey
      add_foreign_key [:vm_id], :vm, name: :app_process_member_vm_id_fkey
    end
  end
end
