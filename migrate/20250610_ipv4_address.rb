# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:ipv4_address) do
      column :ip, :inet, primary_key: true
      foreign_key :cidr, :address, key: :cidr, type: :cidr, null: false

      index [:cidr, :ip], name: :ipv4_address_cidr_ip_idx
      constraint(:ip_is_ipv4) { {family(:ip) => 4} }
      constraint(:ip_is_in_cidr, Sequel.lit("ip <<= cidr"))
    end
  end
end
