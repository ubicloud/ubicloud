# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:ipsec_tunnel) do
      add_unique_constraint [:src_nic_id, :dst_nic_id]
    end
  end
end
