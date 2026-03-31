# frozen_string_literal: true

require "yaml"

class OptionTreeFilter
  @data = YAML.load_file("config/instance_availability.yml")

  def self.data
    @data
  end

  def self.filter(**options)
    filter_data(data, **options)
  end

  def self.filter_data(data, **options)
    providers = data&.[]("providers")
    return [] unless providers

    results = []

    providers.each do |provider_name, provider_data|
      next if options[:provider] && options[:provider] != provider_name

      locations = provider_data["locations"]
      next unless locations
      locations.each do |location_name, location_data|
        next if options[:location] && options[:location] != location_name

        families = location_data["families"]
        next unless families
        families.each do |family_name, family_data|
          next if options[:family] && options[:family] != family_name

          sizes = family_data["sizes"]
          next unless sizes
          sizes.each do |size_data|
            size_name = size_data["name"]
            next if options[:size] && options[:size] != size_name

            results << {
              provider: provider_name,
              location: location_name,
              family: family_name,
              size: size_name,
            }.merge(size_data.except("name"))
          end
        end
      end
    end

    results
  end
end
