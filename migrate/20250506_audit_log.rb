# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:audit_log, partition_by: :at, partition_type: :range) do
      column :id, :uuid, default: Sequel.function(:gen_random_ubid_uuid, 321) # "a1" ubid type
      column :at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :ubid_type, :text, null: false      # ubid type for primary object affected
      column :action, :text, null: false         # short identifier, e.g. create, destroy
      column :project_id, :uuid, null: false     # Deliberately not foreign key
      column :subject_id, :uuid, null: false     # Deliberately not foreign key
      column :object_ids, "uuid[]", null: false  # Object or objects affected by the action

      primary_key [:id, :at] # partition key must be part of primary key
      index [:project_id, Sequel.desc(:at)], name: :audit_log_project_id_at_idx
      index [:project_id, :subject_id, Sequel.desc(:at)], name: :audit_log_project_id_subject_id_at_idx
      index :object_ids, type: :gin, name: :audit_log_object_ids_idx
    end

    first_month = Date.new(2025, 5)
    Array.new(14) { |i| first_month.next_month(i) }.each do |month|
      create_table("audit_log_#{month.strftime("%Y_%m")}", partition_of: :audit_log) do
        from month
        to month.next_month
      end
    end
  end
end
