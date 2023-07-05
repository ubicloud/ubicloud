# frozen_string_literal: true

Sequel.migration do
  change do
    create_table :project do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :name, :text, collate: '"C"', null: false, unique: true
    end

    create_table :access_tag do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :project_id, :project, type: :uuid, null: false
      column :hyper_tag_id, :uuid, null: true
      column :hyper_tag_table, :text, collate: '"C"', null: false
      column :name, :text, collate: '"C"', null: false

      index [:project_id, :hyper_tag_id], unique: true
      index [:project_id, :name], unique: true
    end

    create_table :applied_tag do
      foreign_key :access_tag_id, :access_tag, type: :uuid, null: false
      column :tagged_id, :uuid, null: false
      column :tagged_table, :text, collate: '"C"', null: false

      index [:access_tag_id, :tagged_id], unique: true
      index :tagged_id
    end

    create_table :access_policy do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :project_id, :project, type: :uuid, null: false
      column :name, :text, collate: '"C"', null: false
      column :body, :jsonb, null: false

      index [:project_id, :name], unique: true
    end
  end
end
