# frozen_string_literal: true

Sequel.migration do
  up do
    rename_table(:location_aws_az, :location_az)

    # Create updatable view so existing code using `location_aws_az` continues to work
    create_view(:location_aws_az, from(:location_az))
  end

  down do
    drop_view(:location_aws_az)
    rename_table(:location_az, :location_aws_az)
  end
end
