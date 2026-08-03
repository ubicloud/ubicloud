# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:run_command) do
      # UBID.to_base32_n("rc") => 780
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(780)")
      column :command, :text, null: false
      column :status, :text, null: false, default: "created"
      column :output, :text
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :run_at, :timestamptz

      foreign_key :vm_id, :vm, type: :uuid, null: false

      index :vm_id

      constraint(:run_command_status_check, status: %w[created succeeded failed])
    end
  end
end
