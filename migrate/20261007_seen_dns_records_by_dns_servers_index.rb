# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:seen_dns_records_by_dns_servers) do
      add_index [:dns_record_id, :dns_server_id], concurrently: true
    end
  end
end
