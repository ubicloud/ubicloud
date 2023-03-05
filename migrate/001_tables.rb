# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:strand) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :parent_id, :strand, type: :uuid
      column :schedule, :timestamptz, null: false, default: Sequel.lit("now()")
      column :lease, :timestamptz
      column :prog, :text, collate: '"C"', null: false
      column :label, :text, collate: '"C"', null: false
      column :stack, :jsonb, null: false, default: "[]"
      column :exitval, :jsonb
      column :retval, :jsonb
    end

    create_table(:semaphore) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :consumer, :strand, type: :uuid, null: false
      column :name, :text, collate: '"C"', null: false
    end

    create_table(:sshable) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :host, :text, collate: '"C"', null: false, unique: true
      column :private_key, :text, collate: '"C"', null: false
    end
  end
end
