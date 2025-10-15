# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:firewalls_vms) do
      foreign_key :firewall_id, :firewall, type: :uuid, on_delete: :cascade
      foreign_key :vm_id, :vm, type: :uuid, on_delete: :cascade
      primary_key [:firewall_id, :vm_id]
      index [:vm_id, :firewall_id]
    end
  end
end
