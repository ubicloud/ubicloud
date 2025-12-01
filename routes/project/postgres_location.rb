# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "postgres-location") do |r|
    r.get true do
      authorize("Postgres:view", @project)
      {items: filter_with_availability(vm_families_for_project(@project)).map { |l| Serializers::PostgresLocation.serialize_internal(l) }}
    end
  end

  def filter_with_availability(postgres_locations, accept_missing_provider_availability: false)
    postgres_locations.filter_map do |pg_location|
      location = pg_location.location

      # Only apply AWS availability filtering to AWS locations
      unless location.provider == "aws"
        next pg_location
      end

      # Get available families for this location from the instance availability data
      available_data = OptionTreeFilter.filter(provider: "aws", location: location.name)

      # Handle missing provider availability
      if available_data.empty?
        if accept_missing_provider_availability
          # Return as-is without filtering
          next pg_location
        else
          # Skip this location
          next nil
        end
      end

      # Create a set of available family+size combinations for quick lookup
      available_combinations = Set.new
      available_data.each do |entry|
        available_combinations << [entry[:family], entry[:size]]
      end

      # Filter families and sizes based on availability
      filtered_families = pg_location.available_vm_families.select do |family|
        # Filter sizes within this family
        available_sizes = family[:sizes].select do |size|
          available_combinations.include?([family[:name], size[:name]])
        end

        # Only include the family if it has at least one available size
        if available_sizes.any?
          family[:sizes] = available_sizes
          true
        else
          false
        end
      end

      # Return a new PostgresLocation with filtered families
      PostgresLocation.new(
        pg_location.location,
        pg_location.available_postgres_versions,
        filtered_families
      )
    end
  end
end
