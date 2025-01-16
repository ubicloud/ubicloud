# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    add_index :usage_alert, [:project_id, :user_id, :name], name: :usage_alert_project_id_user_id_name_uidx, unique: true, concurrently: true
    drop_index :usage_alert, [:project_id, :name], name: :usage_alert_project_id_name_uidx, unique: true, concurrently: true
  end

  down do
    add_index :usage_alert, [:project_id, :name], name: :usage_alert_project_id_name_uidx, unique: true, concurrently: true
    drop_index :usage_alert, [:project_id, :user_id, :name], name: :usage_alert_project_id_user_id_name_uidx, unique: true, concurrently: true
  end
end
