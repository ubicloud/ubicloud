# frozen_string_literal: true

Sequel.migration do
  change do
    # A fixed window per source address for the anonymous create path. It is a
    # counter rather than a row per attempt so that the check is one upsert,
    # and it is a table rather than process memory so that the limit holds
    # across web processes.
    create_table(:postgres_ember_rate_limit) do
      column :ip, :inet, null: false
      column :window_start, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      Integer :count, null: false, default: 0
      primary_key [:ip]
    end
  end
end
