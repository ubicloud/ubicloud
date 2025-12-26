# frozen_string_literal: true

require "yaml"

class OptionTreeFilter
  # :nocov:
  def self.freeze
    data
    super
  end
  # :nocov:

  def self.data
    @data ||= YAML.load_file("config/instance_availability.yml")
  end

  # Filter based on provided options hash
  # Example: filter(provider: "aws", location: "us-east-1")
  # Returns array of matching entries with all their attributes
  def self.filter(**options)
    # :nocov:
    return [] unless data && data["providers"]
    # :nocov:

    results = []

    data["providers"].each do |provider_name, provider_data|
      next if options[:provider] && options[:provider] != provider_name

      locations = provider_data["locations"] || {}
      locations.each do |location_name, location_data|
        next if options[:location] && options[:location] != location_name

        families = location_data["families"] || {}
        families.each do |family_name, family_data|
          next if options[:family] && options[:family] != family_name

          sizes = family_data["sizes"] || []
          sizes.each do |size_data|
            size_name = size_data["name"]
            next if options[:size] && options[:size] != size_name

            results << {
              provider: provider_name,
              location: location_name,
              family: family_name,
              size: size_name
            }.merge(size_data.except("name"))
          end
        end
      end
    end

    results
  end

  # :nocov:
  # Get all available options for a specific level
  def self.available_options(level)
    case level
    when :providers
      data["providers"]&.keys || []
    when :locations
      locations = []
      data["providers"]&.each do |_, provider_data|
        locations.concat(provider_data["locations"]&.keys || [])
      end
      locations.uniq
    when :families
      families = []
      data["providers"]&.each do |_, provider_data|
        provider_data["locations"]&.each do |_, location_data|
          families.concat(location_data["families"]&.keys || [])
        end
      end
      families.uniq
    when :sizes
      sizes = []
      data["providers"]&.each do |_, provider_data|
        provider_data["locations"]&.each do |_, location_data|
          location_data["families"]&.each do |_, family_data|
            family_data["sizes"]&.each do |size_data|
              sizes << size_data["name"]
            end
          end
        end
      end
      sizes.uniq
    else
      []
    end
  end
end

if $0 == __FILE__
  p OptionTreeFilter.filter(provider: "aws", location: "us-east-1")
  p OptionTreeFilter.available_options(:providers)
  p OptionTreeFilter.available_options(:locations)
  p OptionTreeFilter.available_options(:families)
  p OptionTreeFilter.available_options(:sizes)
end

# :nocov:
