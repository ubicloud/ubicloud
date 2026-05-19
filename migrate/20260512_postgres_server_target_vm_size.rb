# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_server) do
      add_column :target_vm_size, :text
    end

    from(:postgres_server)
      .update(target_vm_size: from(:postgres_resource).where(Sequel[:postgres_resource][:id] => Sequel[:postgres_server][:resource_id]).select(:target_vm_size))
  end

  down do
    alter_table(:postgres_server) do
      drop_column :target_vm_size
    end
  end
end
