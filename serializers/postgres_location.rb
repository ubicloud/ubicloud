# frozen_string_literal: true

class Serializers::PostgresLocation < Serializers::Base
  def self.serialize_internal(postgres_location, options = {})
    location = postgres_location.location
    {
      name: location.name,
      display_name: location.display_name,
      ui_name: location.ui_name,
      provider: location.provider,
      visible: location.visible,
      available_postgres_versions: postgres_location.available_postgres_versions,
      available_vm_families: postgres_location.available_vm_families
    }
  end
end
