# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:gcp_vpc) do
      add_column :peer_network, :text, collate: '"C"'
      add_column :peering_state, :text, collate: '"C"'
      add_column :peering_state_message, :text
      add_constraint(:gcp_vpc_peering_state_check, Sequel.lit("peering_state IN ('creating', 'waiting_for_peer', 'active', 'failed', 'deleting')"))
      add_constraint(:gcp_vpc_peering_config_check, Sequel.lit("(peer_network IS NULL) = (peering_state IS NULL)"))
      add_constraint(:gcp_vpc_peering_dedicated_check, Sequel.lit("peer_network IS NULL OR (dedicated_for_subnet_id IS NOT NULL AND NOT is_management)"))
    end
  end
end
