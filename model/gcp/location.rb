# frozen_string_literal: true

class Location < Sequel::Model
  module Gcp
    def pg_gce_image(arch, pg_version, family, target_version: nil)
      rel = PgGceImage
        .where(arch:, family:)
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

    # vm_id => upcoming maintenance window start, for TERMINATE instances only:
    # MIGRATE instances live-migrate without a restart and need no failover.
    def gcp_scheduled_maintenance_events
      return {} unless (credential = location_credential_gcp)
      window_start_by_name = {}
      credential.compute_client.aggregated_list(
        project: credential.project_id,
        filter: "labels.ubicloud = \"#{Config.provider_resource_tag_value}\"",
        return_partial_success: true,
      ).each do |zone, scoped_list|
        if scoped_list.warning&.code == "UNREACHABLE"
          Clog.emit("GCP aggregated_list scope unreachable, skipping", {gcp_maintenance_scope_unreachable: {zone:}})
          next
        end
        scoped_list.instances.each do |instance|
          next unless instance.scheduling.on_host_maintenance == "TERMINATE"
          window_start = instance.resource_status&.upcoming_maintenance&.window_start_time
          next if window_start.to_s.empty?
          window_start_by_name[instance.name] = Time.parse(window_start)
        end
      end
      return {} if window_start_by_name.empty?

      window_start_by_vm_id = {}
      Vm.where(location_id: id, name: window_start_by_name.keys).select_hash_groups(:name, :id).each do |name, vm_ids|
        if vm_ids.one?
          window_start_by_vm_id[vm_ids.first] = window_start_by_name[name]
        else
          Clog.emit("GCP maintenance event name collision across projects, skipping", {gcp_maintenance_name_collision: {location_id: id, name:, vm_ids:}})
        end
      end
      window_start_by_vm_id
    end
  end
end
