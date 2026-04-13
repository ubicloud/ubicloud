# frozen_string_literal: true

Sequel.migration do
  up do
    drop_view(:location_aws_az)
  end

  down do
    create_view(:location_aws_az, from(:location_az))
  end
end
