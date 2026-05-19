# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:gcp_vpc) do
      # Build the partial unique index BEFORE dropping the existing
      # full UNIQUE constraint so there is never a window without
      # shared-row uniqueness. While both exist, the full constraint
      # subsumes the partial; once dropped, the partial takes over.
      add_index [:project_id, :location_id], unique: true, where: {dedicated_for_subnet_id: nil}, name: :gcp_vpc_project_id_location_id_shared_uidx, concurrently: true
    end
  end
end
