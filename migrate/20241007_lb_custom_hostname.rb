# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:load_balancer) do
      add_column :custom_hostname, :text, collate: '"C"', null: true, unique: true
      add_foreign_key :custom_hostname_dns_zone_id, :dns_zone, type: :uuid
    end
  end
end
