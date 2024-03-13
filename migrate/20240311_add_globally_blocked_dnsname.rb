# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:globally_blocked_dnsname) do
      column :id, :uuid, primary_key: true
      column :dns_name, :text, collate: '"C"', null: false, unique: true
      column :ip_list, "inet[]", null: true
      column :last_check_at, :timestamp, null: true
    end
  end
end
