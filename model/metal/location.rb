# frozen_string_literal: true

class Location < Sequel::Model
  module Metal
    private

    def metal_pg_boot_image(pg_version, arch, flavor)
      flavor_suffix = case flavor
      when PostgresResource::Flavor::STANDARD, PostgresResource::Flavor::PARADEDB then ""
      when PostgresResource::Flavor::LANTERN then "#{pg_version}-lantern"
      # :nocov: flavor is a DB enum, unknown values are impossible
      else raise "Unknown PostgreSQL flavor: #{flavor}"
        # :nocov:
      end

      "postgres#{flavor_suffix}-ubuntu-2204"
    end

    def metal_azs
      raise "azs is only valid for aws locations"
    end
  end
end
