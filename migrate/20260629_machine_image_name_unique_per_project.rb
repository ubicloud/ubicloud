# frozen_string_literal: true

Sequel.migration do
  up do
    if (service_project_id = ENV["MACHINE_IMAGES_SERVICE_PROJECT_ID"])
      base = from(:machine_image).where(project_id: service_project_id)
      eu_location_ids = from(:location).where(name: ["hetzner-fsn1", "hetzner-hel1"]).select(:id)
      us_location_ids = from(:location).where(name: "leaseweb-wdc02").select(:id)
      base.where(location_id: eu_location_ids).update(name: Sequel.lit("name || '-eu'"))
      base.where(location_id: us_location_ids).update(name: Sequel.lit("name || '-us'"))
    end

    alter_table(:machine_image) do
      drop_constraint :machine_image_project_id_location_id_name_key
      add_unique_constraint [:project_id, :name], name: :machine_image_project_id_name_key
    end
  end

  down do
    alter_table(:machine_image) do
      drop_constraint :machine_image_project_id_name_key
      add_unique_constraint [:project_id, :location_id, :name], name: :machine_image_project_id_location_id_name_key
    end

    if (service_project_id = ENV["MACHINE_IMAGES_SERVICE_PROJECT_ID"])
      from(:machine_image)
        .where(project_id: service_project_id)
        .where(Sequel.like(:name, "%-eu") | Sequel.like(:name, "%-us"))
        .update(name: Sequel.function(:regexp_replace, :name, "-(eu|us)$", ""))
    end
  end
end
