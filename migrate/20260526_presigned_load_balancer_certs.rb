# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:presigned_load_balancer_cert) do
      uuid :load_balancer_id, primary_key: true # deliberately not foreign key
      foreign_key :cert_id, :cert, type: :uuid, null: false, unique: true
      timestamptz :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP, index: true
    end
  end
end
