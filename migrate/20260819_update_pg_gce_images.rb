# frozen_string_literal: true

Sequel.migration do
  up do
    from(:pg_gce_image)
      .where(gcp_project_id: "", arch: "x64")
      .update(gce_image_name: "postgres-ubuntu-2204-x64-20260819-1-0")
    from(:pg_gce_image)
      .where(gcp_project_id: "", arch: "arm64")
      .update(gce_image_name: "postgres-ubuntu-2204-arm64-20260819-1-0")
  end

  down do
    raise Sequel::Error, "irreversible: previous GCE image names unknown"
  end
end
