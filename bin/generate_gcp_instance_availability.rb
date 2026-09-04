#!/usr/bin/env ruby
# frozen_string_literal: true

# simplecov:disable

require_relative "../loader"
require "google/cloud/compute/v1"
require "yaml"

# Generates the GCP half of config/instance_availability.yml from the Compute
# Engine API; bin/generate_instance_availability.rb generates the AWS half.
#
# Availability is per project: restricted machine types are only listed for
# projects allowlisted for them.
#
# Usage: ruby bin/generate_gcp_instance_availability.rb <gcp_project_id> [output_file_path] [--credentials=path]
class GcpInstanceAvailabilityGenerator
  PROVIDER = "gcp"

  def initialize(gcp_project_id, credentials_path: nil)
    @gcp_project_id = gcp_project_id
    @credentials_path = credentials_path
  end

  # GCE machine type name => [our family, vcpu count], e.g.
  # "z3-highmem-44-standardlssd" => ["z3-standard", 44]
  def machine_type_index
    @machine_type_index ||= Option::GCP_FAMILY_VM_CONFIG.each_with_object({}) do |(family, config), index|
      config[:shapes].each_key do |vcpu|
        index[Option.gcp_instance_type_name(family, vcpu)] = [family, vcpu]
      end
    end
  end

  def generate
    log "Fetching machine types for project #{@gcp_project_id}..."

    # region => family => vcpu => Set of zones offering it. Zones are tracked to
    # warn about partial coverage, which the file format cannot express.
    found = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = Hash.new { |h3, k3| h3[k3] = [] } } }

    client.aggregated_list(project: @gcp_project_id).each do |scope, scoped_list|
      next unless scope.start_with?("zones/")
      zone = scope.delete_prefix("zones/")

      region = zone.sub(/-[a-z]\z/, "")
      Array(scoped_list.machine_types).each do |machine_type|
        next unless (family, vcpu = machine_type_index[machine_type.name])

        found[region][family][vcpu] << zone
      end
    end

    log "Found #{found.size} regions offering at least one known family"
    warn_partial_coverage(found)

    locations = found.sort.to_h do |region, families|
      [
        "#{PROVIDER}-#{region}",
        {"families" => families.sort.to_h { |family, vcpus| [family, {"sizes" => sizes_for(family, vcpus)}] }},
      ]
    end

    {"providers" => {PROVIDER => {"locations" => locations}}}
  end

  private

  def client
    @client ||= Google::Cloud::Compute::V1::MachineTypes::Rest::Client.new do |config|
      config.credentials = @credentials_path if @credentials_path
    end
  end

  def log(msg)
    warn msg
  end

  def sizes_for(family, vcpus)
    config = Option::GCP_FAMILY_VM_CONFIG.fetch(family)
    vcpus.keys.sort.map do |vcpu|
      {
        "name" => "#{family}-#{vcpu}",
        "vcpus" => vcpu,
        "memory_gib" => vcpu * config[:mem_ratio],
        # dup: the same frozen array is shared by every location offering this
        # size, and YAML.dump emits anchors and aliases for repeated objects.
        "storage_size_options" => Option::GCP_STORAGE_SIZE_OPTIONS.fetch(family).fetch(vcpu).dup,
      }
    end
  end

  # A size present in only some zones of a region is still offered there, but
  # cannot spread a high availability cluster across zones. The file format has
  # no zone dimension, so surface it to whoever runs the generator.
  def warn_partial_coverage(found)
    found.sort.each do |region, families|
      zones = families.values.flat_map { it.values.flatten }.uniq
      families.sort.each do |family, vcpus|
        vcpus.sort.each do |vcpu, size_zones|
          size_zones = size_zones.uniq
          next if size_zones.size == zones.size

          log "  partial: #{family}-#{vcpu} in #{region} covers #{size_zones.size} of #{zones.size} zones (#{size_zones.sort.join(", ")})"
        end
      end
    end
  end
end

if __FILE__ == $0
  flags, positional = ARGV.partition { it.start_with?("--") }
  credentials_flags, unknown_flags = flags.partition { it.start_with?("--credentials=") }
  credentials_path = credentials_flags.last&.delete_prefix("--credentials=")&.then { File.expand_path(it) }
  gcp_project_id, output_file = positional
  output_file ||= "config/instance_availability.yml"

  if gcp_project_id.nil? || gcp_project_id.empty? || !unknown_flags.empty?
    puts "Unknown option: #{unknown_flags.join(", ")}" unless unknown_flags.empty?
    puts "Usage: #{$0} <gcp_project_id> [output_file_path] [--credentials=path]"
    puts ""
    puts "Example: #{$0} my-gcp-project config/instance_availability.yml"
    puts "Example: #{$0} my-gcp-project --credentials=~/keys/sa.json"
    puts ""
    puts "Without --credentials, Application Default Credentials are used."
    puts ""
    exit 1
  end

  data = GcpInstanceAvailabilityGenerator.new(gcp_project_id, credentials_path:).generate

  InstanceAvailabilityFile.merge_providers(output_file, data["providers"])
  locations = data["providers"][GcpInstanceAvailabilityGenerator::PROVIDER]["locations"]
  puts "GCP instance availability written to: #{output_file}"
  puts "Total locations: #{locations.size}"
end

# simplecov:enable
