# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:vm_display_state, %w[creating running])

    alter_table(:vm_host) do
      add_column :location, :text, collate: '"C"', null: false
    end

    alter_table(:vm) do
      add_column :display_state, :vm_display_state, default: "creating", null: false
      add_column :name, :text, collate: '"C"', null: false
      add_column :size, String, collate: '"C"', null: false
      add_column :location, String, collate: '"C"', null: false
      add_column :boot_image, String, collate: '"C"', null: false
    end
  end
end
