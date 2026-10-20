#!/usr/bin/env ruby
# frozen_string_literal: true

# simplecov:disable

require_relative "../loader"
require "aws-sdk-ec2"
require "yaml"

# Script to generate instance availability YAML from AWS APIs
# Usage: ruby bin/generate_instance_availability.rb <output_file_path>
#
class InstanceAvailabilityGenerator
  # Instance families we're interested in
  INSTANCE_FAMILIES = Option::AWS_FAMILY_OPTIONS

  def initialize
    @data = {"providers" => {"aws" => {"locations" => {}}}}
    # Facts that do not vary by region, once per instance type.
    @instance_types = {}
    @data_mutex = Mutex.new
    @log_mutex = Mutex.new
  end

  def generate
    log "Fetching available AWS regions..."
    regions = fetch_regions
    log "Found #{regions.size} regions: #{regions.join(", ")}"

    parallel_count = Integer(ENV.fetch("PARALLEL_REGIONS_COUNT", "10"), 10)
    parallel_count = 1 if parallel_count < 1
    log "\nFetching instance types from #{regions.size} regions (#{parallel_count} in parallel)..."

    queue = Queue.new
    regions.each { queue << it }

    workers = Array.new(parallel_count) do
      Thread.new do
        loop do
          region = begin
            queue.pop(true)
          rescue ThreadError
            # queue drained
            break
          end
          log "Processing region: #{region}"
          process_region(region)
        end
      end
    end
    workers.each(&:join)

    # Canonical region order; parallel fetch inserts out of order
    @data["providers"]["aws"]["locations"] = @data["providers"]["aws"]["locations"].sort.to_h
    @data["providers"]["aws"]["instance_types"] = @instance_types.sort.to_h
    @data
  end

  private

  def log(msg)
    @log_mutex.synchronize { puts msg }
  end

  def fetch_regions
    # Use us-east-1 as the default region to query for all available regions
    client = Aws::EC2::Client.new(region: "us-east-1")

    response = client.describe_regions
    response.regions.map(&:region_name).sort
  rescue Aws::EC2::Errors::ServiceError => e
    log "Error fetching regions: #{e.message}"
    log "Falling back to default regions"
    ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "eu-west-1", "eu-central-1", "ap-southeast-1", "ap-northeast-1"]
  end

  def process_region(region)
    client = Aws::EC2::Client.new(region:)

    # Get all instance types available in the region
    instance_types = []
    next_token = nil

    loop do
      response = client.describe_instance_types({
        max_results: 100,
        next_token:,
      })

      instance_types.concat(response.instance_types)
      next_token = response.next_token
      break if next_token.nil?
    end

    # Filter and organize by family
    families = {}

    instance_types.each do |instance_type|
      type_name = instance_type.instance_type
      family = extract_family(type_name)

      # Skip if not in our interested families
      next unless INSTANCE_FAMILIES.include?(family)

      # The file records a type once, so a region that reports it differently
      # needs a per-location override before it can be written.
      facts = instance_type_facts(instance_type)
      @data_mutex.synchronize do
        known = (@instance_types[type_name] ||= facts)
        fail "#{type_name} in #{region} differs from another region: #{facts} vs #{known}" unless known == facts
      end
      families[family] ||= []
      families[family] << type_name
    end

    # Sort sizes within each family
    families.each_value do |sizes|
      sizes.sort_by! { @instance_types[it].values_at("vcpus", "memory_gib") }
    end

    # Add to data structure if we found any instances
    unless families.empty?
      @data_mutex.synchronize do
        @data["providers"]["aws"]["locations"][region] = {
          "families" => families.sort.to_h,
        }
      end
    end
  rescue Aws::EC2::Errors::ServiceError => e
    log "Error processing region #{region}: #{e.message}"
  end

  def extract_family(instance_type)
    # Extract family from instance type (e.g., "i8g.large" -> "i8g")
    instance_type.split(".").first
  end

  # What a type offers in every region. Local storage is recorded only as
  # identical NVMe SSDs, [count, size_gb], whose sizes add up to the total AWS
  # reports, and storage_size_options is derived from them; EBS limits are
  # in MB/s.
  def instance_type_facts(instance_type)
    facts = {
      "vcpus" => instance_type.v_cpu_info.default_v_cpus,
      "memory_gib" => instance_type.memory_info.size_in_mi_b / 1024,
      "storage_size_options" => [],
    }
    if (storage = instance_type.instance_storage_info)
      name = instance_type.instance_type
      disks = storage.disks
      fail "#{name}: local disks of several kinds" unless disks.size == 1
      disk = disks.first
      fail "#{name}: local disks are #{disk.type}, not NVMe SSD" unless disk.type == "ssd" && storage.nvme_support == "required"
      fail "#{name}: #{disk.count} x #{disk.size_in_gb} GB is not the #{storage.total_size_in_gb} GB total" unless disk.count * disk.size_in_gb == storage.total_size_in_gb
      facts["local_disks"] = [disk.count, disk.size_in_gb]
      facts["storage_size_options"] = [disk.count * disk.size_in_gb]
    end
    if (ebs = instance_type.ebs_info&.ebs_optimized_info)
      facts["ebs"] = {
        "baseline_iops" => ebs.baseline_iops,
        "baseline_throughput_mbps" => ebs.baseline_throughput_in_m_bps,
        "maximum_iops" => ebs.maximum_iops,
        "maximum_throughput_mbps" => ebs.maximum_throughput_in_m_bps,
      }
    end
    facts
  end
end

# Main execution
if __FILE__ == $0
  output_file = ARGV[0]
  if output_file.nil? || output_file.empty?
    puts "Usage: #{$0} <output_file_path>"
    puts ""
    puts "Example: #{$0} config/instance_availability.yml"
    puts ""
    exit 1
  end
  puts "Generating instance availability data to #{output_file}..."
  generator = InstanceAvailabilityGenerator.new
  data = generator.generate

  InstanceAvailabilityFile.merge_providers(output_file, data["providers"])
  puts "\nInstance availability data written to: #{output_file}"
  puts "Total regions: #{data["providers"]["aws"]["locations"].keys.size}"
  puts "Regions: #{data["providers"]["aws"]["locations"].keys.join(", ")}"
end

# simplecov:enable
