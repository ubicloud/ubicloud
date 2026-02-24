# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vm_metal) do
      column :id, :uuid, primary_key: true
      foreign_key [:id], :vm
      column :fscrypt_key, :text
      column :fscrypt_key_2, :text
    end

    alter_table(:vm_host) do
      add_column :fsencrypt_capable, :boolean, null: false, default: false
    end
  end
end
