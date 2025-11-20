# frozen_string_literal: true

class PostgresResource < Sequel::Model
  module Gcp
    def self.available_families_and_sizes(_location, _project)
      Set.new(
        Option::POSTGRES_SIZE_OPTIONS.filter_map { |name, opt| [opt.family, name] if Option::GCP_FAMILY_OPTIONS.include?(opt.family) },
      )
    end

    def self.storage_sizes(_location, family, vcpu_count)
      Option::GCP_STORAGE_SIZE_OPTIONS[family][vcpu_count]
    end

    private

    def gcp_boot_image(pg_version, arch)
      location.pg_gce_image(arch, pg_version, target_version:)
    end

    def gcp_upgrade_candidate_server
      eligible_image_names = PgGceImage
        .where(Sequel.pg_array_op(:pg_versions).contains(Sequel.pg_array([target_version], :text)))
        .select_map(:gce_image_name)
      servers
        .reject(&:is_representative)
        .select { |server| eligible_image_names.include?(server.vm.boot_image.split("/").last) }
        .max_by(&:created_at)
    end

    def gcp_lockout_mechanisms
      ["pg_stop", "hba"].freeze
    end

    def gcp_new_server_exclusion_filters
      exclude_availability_zones, availability_zone = if use_different_az_set?
        # Only exclude AZs of servers that will remain after convergence. Servers
        # that need recycling or are being destroyed will leave their AZ, so it
        # should be available for the replacement.
        active_vm_ids = servers.reject { |s| s.needs_recycling? || s.destroy_set? }.map(&:vm_id)
        zone_suffixes = VmGcpResource
          .join(:location_az, id: :location_az_id)
          .where(Sequel[:vm_gcp_resource][:id] => active_vm_ids)
          .distinct
          .select_map(Sequel[:location_az][:az])

        [zone_suffixes, nil]
      else
        [[], representative_server.vm.vm_gcp_resource.location_az.az]
      end
      ServerExclusionFilters.new(exclude_host_ids: [], exclude_data_centers: [], exclude_availability_zones:, availability_zone:)
    end
  end
end
