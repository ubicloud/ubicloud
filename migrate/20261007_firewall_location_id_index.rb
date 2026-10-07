# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:firewall) do
      # Only needed for deleting private locations, so exclude the constant locations in Location
      add_index :location_id, where: Sequel.~(location_id: [
        "caa7a807-36c5-8420-a75c-f906839dad71", # HETZNER_FSN1_ID
        "1f214853-0bc4-8020-b910-dffb867ef44f", # HETZNER_HEL1_ID
        "6b9ef786-b842-8420-8c65-c25e3d4bdf3d", # GITHUB_RUNNERS_ID
        "e0865080-9a3d-8020-a812-f5817c7afe7f", # LEASEWEB_WDC02_ID
      ]), name: :firewall_location_id_private_idx, concurrently: true
    end
  end
end
