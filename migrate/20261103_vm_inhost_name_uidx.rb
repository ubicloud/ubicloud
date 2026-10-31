# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:vm) do
      add_index [:vm_host_id, Sequel.lit("((get_byte(uuid_send(id), 0) << 22) | (get_byte(uuid_send(id), 1) << 14) | (get_byte(uuid_send(id), 2) << 6) | (get_byte(uuid_send(id), 3) >> 2))")],
        unique: true, name: :vm_vm_host_id_inhost_name_uidx, concurrently: true
    end
  end
end
