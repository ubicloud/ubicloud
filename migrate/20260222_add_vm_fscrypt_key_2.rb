# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:vm) do
      add_column :fscrypt_key_2, :text
    end
  end

  down do
    alter_table(:vm) do
      drop_column :fscrypt_key_2
    end
  end
end
