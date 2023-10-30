# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:arch, %w[x64 arm64])

    alter_table(:vm_host) do
      add_column :arch, :arch
    end

    alter_table(:vm) do
      add_column :arch, :arch, default: "x64", null: false
    end
  end
end
