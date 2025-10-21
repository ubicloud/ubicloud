# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
    INSERT INTO pg_aws_ami (id, aws_location_name, arch, pg_version, aws_ami_id) VALUES
      ('853b1491-1f0c-42db-8f38-c916994e32f4', 'us-west-2', 'x64', '18', 'ami-0090a7d48d9b50181'),
      ('5afada23-bff8-4501-a8f6-ecd146ac2ec5', 'us-east-1', 'x64', '18', 'ami-0631c83abb0823706'),
      ('712a83cb-78b9-48c8-b534-f78e615c586f', 'us-east-2', 'x64', '18', 'ami-0ba56319c75bf49eb'),
      ('afe42abc-2677-49c5-94e5-ecf6b0eb263c', 'ap-southeast-2', 'x64', '18', 'ami-0aaf00dda04ba4a26'),
      ('346ecf7a-e951-41ab-be89-1721ef5d4a5c', 'us-west-2', 'arm64', '18', 'ami-01f9b35cfc74cc771'),
      ('7fbc5982-4c15-4d82-a6a1-4c8234cd4d63', 'us-east-1', 'arm64', '18', 'ami-0baa492ac58de86cd'),
      ('866a6dff-0ff6-4062-8ec7-79e94a983513', 'us-east-2', 'arm64', '18', 'ami-0c79ded8114765259'),
      ('c8a27e42-81a9-49a0-90d0-5586058f4739', 'ap-southeast-2', 'arm64', '18', 'ami-0035250352cebef6e');

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0090a7d48d9b50181' WHERE aws_location_name = 'us-west-2' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0631c83abb0823706' WHERE aws_location_name = 'us-east-1' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0ba56319c75bf49eb' WHERE aws_location_name = 'us-east-2' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0aaf00dda04ba4a26' WHERE aws_location_name = 'ap-southeast-2' AND arch = 'x64';

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-01f9b35cfc74cc771' WHERE aws_location_name = 'us-west-2' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0baa492ac58de86cd' WHERE aws_location_name = 'us-east-1' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0c79ded8114765259' WHERE aws_location_name = 'us-east-2' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0035250352cebef6e' WHERE aws_location_name = 'ap-southeast-2' AND arch = 'arm64';
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM pg_aws_ami WHERE pg_version = '18';

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0bc7b6956585986f5' WHERE aws_location_name = 'us-west-2' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-05a2ef47f1585a154' WHERE aws_location_name = 'us-east-1' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0a8e69108989ceb0c' WHERE aws_location_name = 'us-east-2' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-09f9ad90f0f13c68e' WHERE aws_location_name = 'ap-southeast-2' AND arch = 'x64';

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-097054b37f4e3fbc7' WHERE aws_location_name = 'us-west-2' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0be54bcfe8d8e39c1' WHERE aws_location_name = 'us-east-1' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0bf351094e5a6e38f' WHERE aws_location_name = 'us-east-2' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0df496cf9c499b2c5' WHERE aws_location_name = 'ap-southeast-2' AND arch = 'arm64';
    SQL
  end
end
