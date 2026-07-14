# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:vm_gcp_resource) do
      add_column :service_account_email, :text
    end

    alter_table(:location_credential_gcp) do
      set_column_allow_null :credentials_json
    end
  end

  down do
    alter_table(:vm_gcp_resource) do
      drop_column :service_account_email
    end

    alter_table(:location_credential_gcp) do
      set_column_not_null :credentials_json
    end
  end
end
