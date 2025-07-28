# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:account_otp_unlocks) do
      foreign_key :id, :accounts, primary_key: true, type: :uuid
      Integer :num_successes, null: false, default: 1
      Time :next_auth_attempt_after, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
