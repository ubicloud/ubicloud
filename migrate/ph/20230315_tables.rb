# frozen_string_literal: true

# See
# https://github.com/jeremyevans/rodauth/blob/60beccf51087c74794d6d4cdffd1d1875345ac9c/README.rdoc#label-Creating+tables,
# though :Bignum types have been replaced with :uuid.

require "rodauth/migrations"

Sequel.migration do
  up do
    create_table(:account_password_hashes) do
      foreign_key :id, :accounts, primary_key: true, type: :uuid
      String :password_hash, null: false
    end
    Rodauth.create_database_authentication_functions(self, argon2: true)

    user = get(Sequel.lit("current_user")).delete_suffix("_password")
    run "REVOKE ALL ON account_password_hashes FROM public"
    run "REVOKE ALL ON FUNCTION rodauth_get_salt(uuid) FROM public"
    run "REVOKE ALL ON FUNCTION rodauth_valid_password_hash(uuid, text) FROM public"
    run "GRANT INSERT, UPDATE, DELETE ON account_password_hashes TO #{user}"
    run "GRANT SELECT(id) ON account_password_hashes TO #{user}"
    run "GRANT EXECUTE ON FUNCTION rodauth_get_salt(uuid) TO #{user}"
    run "GRANT EXECUTE ON FUNCTION rodauth_valid_password_hash(uuid, text) TO #{user}"

    # Used by the disallow_password_reuse feature
    create_table(:account_previous_password_hashes) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :account_id, :accounts, type: :uuid
      String :password_hash, null: false
    end
    Rodauth.create_database_previous_password_check_functions(self, argon2: true)

    user = get(Sequel.lit("current_user")).delete_suffix("_password")
    run "REVOKE ALL ON account_previous_password_hashes FROM public"
    run "REVOKE ALL ON FUNCTION rodauth_get_previous_salt(uuid) FROM public"
    run "REVOKE ALL ON FUNCTION rodauth_previous_password_hash_match(uuid, text) FROM public"
    run "GRANT INSERT, UPDATE, DELETE ON account_previous_password_hashes TO #{user}"
    run "GRANT SELECT(id, account_id) ON account_previous_password_hashes TO #{user}"
    run "GRANT EXECUTE ON FUNCTION rodauth_get_previous_salt(uuid) TO #{user}"
    run "GRANT EXECUTE ON FUNCTION rodauth_previous_password_hash_match(uuid, text) TO #{user}"
  end

  down do
    Rodauth.drop_database_previous_password_check_functions(self)
    Rodauth.drop_database_authentication_functions(self)
    drop_table(:account_previous_password_hashes, :account_password_hashes)
  end
end
