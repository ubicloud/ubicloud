# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      UPDATE private_subnet_aws_resource
      SET user_security_group_id = security_group_id, mgmt_security_group_id = security_group_id
      WHERE user_security_group_id IS NULL AND mgmt_security_group_id IS NULL AND security_group_id IS NOT NULL;
    SQL
  end

  down do
    # No-op: this is a backfill of the new columns
  end
end
