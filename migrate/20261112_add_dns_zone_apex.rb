# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:dns_zone) do
      add_column :nameservers, "text[]", collate: '"C"'
      add_column :soa_email, :text, collate: '"C"'
      add_column :revert_apex, :boolean, null: false, default: false
    end
  end
end
