# frozen_string_literal: true

require "rodauth/migrations"

Sequel.migration do
  up do
    create_table(:admin_password_hash) do
      foreign_key :id, :admin_account, primary_key: true, type: :uuid, on_delete: :cascade
      String :password_hash, null: false
    end
    Rodauth.create_database_authentication_functions(self, argon2: true, table_name: :admin_password_hash, get_salt_name: :rodauth_admin_get_salt, valid_hash_name: :rodauth_admin_valid_password_hash)

    user = get(Sequel.lit("current_user")).delete_suffix("_password")
    run "REVOKE ALL ON admin_password_hash FROM public"
    run "REVOKE ALL ON FUNCTION rodauth_admin_get_salt(uuid) FROM public"
    run "REVOKE ALL ON FUNCTION rodauth_admin_valid_password_hash(uuid, text) FROM public"
    run "GRANT INSERT, UPDATE, DELETE ON admin_password_hash TO #{user}"
    run "GRANT SELECT(id) ON admin_password_hash TO #{user}"
    run "GRANT EXECUTE ON FUNCTION rodauth_admin_get_salt(uuid) TO #{user}"
    run "GRANT EXECUTE ON FUNCTION rodauth_admin_valid_password_hash(uuid, text) TO #{user}"
  end

  down do
    Rodauth.drop_database_authentication_functions(self, table_name: :admin_password_hash, get_salt_name: :rodauth_admin_get_salt, valid_hash_name: :rodauth_admin_valid_password_hash)
    drop_table(:admin_password_hash)
  end
end
