# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO pg_aws_ami (id, aws_location_name, aws_ami_id, pg_version) VALUES
        ('ca8e3503-fd3f-8dda-b559-ac733c7f6b4f', 'us-east-2', 'ami-05403488066ce85e5', '16'),
        ('ef803758-3479-85da-8590-09fb137e4642', 'us-east-2', 'ami-0badeb4aed1febf46', '17')
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM pg_aws_ami WHERE aws_location_name = 'us-east-2'
    SQL
  end
end
