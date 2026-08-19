# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_gcp_resource) do
      add_column :service_account_email, :text, collate: '"C"'
    end

    alter_table(:location_credential_gcp) do
      set_column_allow_null :credentials_json
    end
  end
end
