# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:private_subnet) do
      drop_column :state
    end

    alter_table(:vm) do
      drop_column :display_state
    end

    drop_enum(:vm_display_state)
  end

  down do
    create_enum(:vm_display_state, %w[creating running rebooting starting deleting])

    alter_table(:vm) do
      add_column :display_state, :vm_display_state, default: "creating", null: false
    end

    alter_table(:private_subnet) do
      add_column :state, :text, null: false, default: "creating"
    end
  end
end
