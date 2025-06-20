# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:pg_aws_ami) do
      column :id, :uuid, primary_key: true
      column :aws_location_name, :text
      column :aws_ami_id, :text
      column :pg_version, :text

      index [:aws_location_name, :pg_version], unique: true
    end

    run <<~SQL
      INSERT INTO pg_aws_ami (id, aws_location_name, aws_ami_id, pg_version) VALUES
        ('e0870f69-19b8-81da-8e4a-51231bf3ac19', 'us-west-2', 'ami-0c54521352e6e92bb', '16'),
        ('4164c2d4-0ec7-85da-bcc5-5c8e59a07dac', 'us-west-2', 'ami-0ba58268c42166e1d', '17')
    SQL
  end

  down do
    drop_table(:pg_aws_ami)
  end
end
