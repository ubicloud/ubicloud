# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:gcp_vpc) do
      # Each subnet can own at most one dedicated VPC; without this
      # partial unique, two concurrent strands for the same subnet
      # could both miss the lookup-by-dedicated_for_subnet_id and
      # both assemble a dedicated VPC for it.
      add_index :dedicated_for_subnet_id, unique: true, where: Sequel.lit("dedicated_for_subnet_id IS NOT NULL"), name: :gcp_vpc_dedicated_for_subnet_id_uidx, concurrently: true
    end
  end
end
