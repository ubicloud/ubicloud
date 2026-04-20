# frozen_string_literal: true

class Location < Sequel::Model
  module Gcp
    def pg_gce_image(arch, pg_version, target_version: nil)
      rel = PgGceImage
        .where(arch:)
        .where(Sequel.pg_array_op(:pg_versions).contains(Sequel.pg_array([pg_version], :text)))
      if target_version && target_version != pg_version
        dual = rel
          .where(Sequel.pg_array_op(:pg_versions).contains(Sequel.pg_array([target_version], :text)))
          .order(:gce_image_name)
          .first
        raise "No dual-version GCE image found for arch #{arch} covering pg_version=#{pg_version} + target_version=#{target_version}; cannot provision upgrade standby" unless dual
        return "projects/#{Config.postgres_gce_image_gcp_project_id}/global/images/#{dual.gce_image_name}"
      end
      image = rel.order(:gce_image_name).first
      raise "No GCE image found for arch #{arch} and pg_version #{pg_version}" unless image
      "projects/#{Config.postgres_gce_image_gcp_project_id}/global/images/#{image.gce_image_name}"
    end

    private

    def gcp_azs
      v = location_azs_dataset.all
      return v unless v.empty?
      set_gcp_azs
    end

    def set_gcp_azs
      region = name.delete_prefix("gcp-")
      prefix = "#{region}-"
      get_gcp_zones(region, prefix).map do |zone|
        az = zone.name.delete_prefix(prefix)
        LocationAz.create(location_id: id, az:)
      end
    end

    def get_gcp_zones(region, prefix = "#{region}-")
      credential = location_credential_gcp
      zones = credential.zones_client.list(project: credential.project_id).to_a
      zones.select { it.name.start_with?(prefix) }
    end
  end
end
