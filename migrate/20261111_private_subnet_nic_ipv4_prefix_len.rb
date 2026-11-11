# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:private_subnet) do
      add_column :nic_ipv4_prefix_len, Integer
      add_constraint({name: :private_subnet_nic_ipv4_prefix_len_check, not_valid: true},
        Sequel.lit("nic_ipv4_prefix_len IS NULL OR (nic_ipv4_prefix_len > masklen(net4) AND nic_ipv4_prefix_len <= 32)"))
    end
  end
end
