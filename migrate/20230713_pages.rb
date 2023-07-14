# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:page) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :incident_key, :text, collate: '"C"', default: Sequel.lit("md5(random()::text)")
      column :summary, :text, collate: '"C"'
      column :resolved_at, :timestamptz
    end
  end
end
