# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:strand) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :parent, :strand, type: :uuid
      column :schedule, :timestamptz, null: false
      column :lease, :timestamptz
      column :cprog, :text, collate: '"C"', null: false
      column :label, :text, collate: '"C"', null: false
      column :stack, :jsonb, null: false, default: "[]"
      column :retval, :jsonb, null: false, default: "{}"
    end

    create_table(:semaphore) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :strand_id, :strand, type: :uuid, null: false
      column :name, :text, collate: '"C"', null: false
    end
  end
end
