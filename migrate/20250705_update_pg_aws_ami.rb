# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      TRUNCATE pg_aws_ami;
      INSERT INTO pg_aws_ami (id, aws_location_name, aws_ami_id, pg_version, arch) VALUES
        ('bc4fb7f0-09ab-4eff-aa2e-440f77a425f1', 'us-west-2', 'ami-09819c59f3862852c', '16', 'x64'),
        ('5d34874f-58a0-437f-ba5d-fe358f338513', 'us-west-2', 'ami-047c1c49b65c59f0e', '16', 'arm64'),
        ('008243e5-09ed-4a0d-9b41-b7d30f406877', 'us-west-2', 'ami-0b3f79d4f66755ab9', '17', 'x64'),
        ('7bed2c64-31df-43cd-a4c7-99b911c4b15e', 'us-west-2', 'ami-013f7750dfb4ce4e7', '17', 'arm64');
    SQL

    alter_table(:pg_aws_ami) do
      set_column_not_null :arch
    end
  end

  down do
    run <<~SQL
      TRUNCATE pg_aws_ami;
      INSERT INTO pg_aws_ami (id, aws_location_name, aws_ami_id, pg_version, arch) VALUES
        ('e0870f69-19b8-81da-8e4a-51231bf3ac19', 'us-west-2', 'ami-0c54521352e6e92bb', '16', 'x64'),
        ('4164c2d4-0ec7-85da-bcc5-5c8e59a07dac', 'us-west-2', 'ami-0ba58268c42166e1d', '17', 'x64');
    SQL
  end
end
