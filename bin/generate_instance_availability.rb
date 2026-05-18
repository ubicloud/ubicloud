#!/usr/bin/env ruby
# frozen_string_literal: true

# :nocov:

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
  end

  def generate
    puts "Fetching available AWS regions..."
    regions = fetch_regions
    puts "Found #{regions.size} regions: #{regions.join(", ")}"

    puts "\nFetching instance types from AWS regions..."

    regions.each do |region|
      puts "Processing region: #{region}"
      process_region(region)
    end

    @data
  end

  private

  def fetch_regions
    # Use us-east-1 as the default region to query for all available regions
    client = Aws::EC2::Client.new(region: "us-east-1")

    response = client.describe_regions
    response.regions.map(&:region_name).sort
  rescue Aws::EC2::Errors::ServiceError => e
    puts "Error fetching regions: #{e.message}"
    puts "Falling back to default regions"
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

      families[family] ||= []
      families[family] << {
        "name" => type_name,
        "vcpus" => instance_type.v_cpu_info.default_v_cpus,
        "memory_gib" => instance_type.memory_info.size_in_mi_b / 1024,
        "storage_size_options" => extract_storage_options(instance_type),
      }
    end

    # Sort sizes within each family
    families.each do |family, sizes|
      sizes.sort_by! { |s| [s["vcpus"], s["memory_gib"]] }
    end

    # Add to data structure if we found any instances
    unless families.empty?
      @data["providers"]["aws"]["locations"][region] = {
        "families" => families.sort.to_h.transform_values { |sizes| {"sizes" => sizes} },
      }
    end
  rescue Aws::EC2::Errors::ServiceError => e
    puts "Error processing region #{region}: #{e.message}"
  end

  def extract_family(instance_type)
    # Extract family from instance type (e.g., "i8g.large" -> "i8g")
    instance_type.split(".").first
  end

  def extract_storage_options(instance_type)
    # Check if instance storage is supported
    return [] unless instance_type.instance_storage_supported

    # Extract storage information from instance storage
    storage_info = instance_type.instance_storage_info
    return [] if storage_info.nil?

    # Get total storage in GB
    total_storage = storage_info.total_size_in_gb || 0

    (total_storage > 0) ? [total_storage] : []
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

  # Write to YAML file
  File.write(output_file, YAML.dump(data))
  puts "\nInstance availability data written to: #{output_file}"
  puts "Total regions: #{data["providers"]["aws"]["locations"].keys.size}"
  puts "Regions: #{data["providers"]["aws"]["locations"].keys.join(", ")}"
end

# :nocov:
