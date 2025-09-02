# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_custom_label) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :installation_id, :github_installation, type: :uuid, null: false
      column :label, :text, null: false, unique: true
      column :alias_for, :text, null: false
      column :limits, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      unique [:installation_id, :label]
    end
  end
end
