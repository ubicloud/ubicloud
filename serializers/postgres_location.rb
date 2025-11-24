# frozen_string_literal: true

class Serializers::PostgresLocation < Serializers::Base
  def self.serialize_internal(postgres_location, options = {})
    {
      name: postgres_location.location.name,
      display_name: postgres_location.location.display_name,
      ui_name: postgres_location.location.ui_name,
      provider: postgres_location.location.provider,
      visible: postgres_location.location.visible,
      available_postgres_versions: postgres_location.available_postgres_versions,
      available_vm_families: postgres_location.available_vm_families
    }
  end
end
