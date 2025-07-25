# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:admin_account) do
      # UBID.to_base32_n("et") => 474
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(474)")
      citext :login, null: false, unique: true
    end

    create_table(:admin_webauthn_user_id) do
      foreign_key :id, :admin_account, primary_key: true, type: :uuid, on_delete: :cascade
      String :webauthn_id, null: false
    end

    create_table(:admin_webauthn_key) do
      foreign_key :account_id, :admin_account, type: :uuid, on_delete: :cascade
      String :webauthn_id
      String :public_key, null: false
      Integer :sign_count, null: false
      Time :last_use, null: false, default: Sequel::CURRENT_TIMESTAMP
      primary_key [:account_id, :webauthn_id]
    end

    user = get(Sequel.lit("current_user")) + "_password"
    run "GRANT REFERENCES ON admin_account TO #{user}"
  end

  down do
    drop_table(:admin_webauthn_key, :admin_webauthn_user_id, :admin_account)
  end
end
