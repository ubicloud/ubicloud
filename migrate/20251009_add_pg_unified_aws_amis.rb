# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
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

  down do
    run <<~SQL
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-033db45b22ea9d5f5' WHERE aws_location_name = 'us-west-2' AND pg_version = '16' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0eb8c2917209d976c' WHERE aws_location_name = 'us-east-1' AND pg_version = '16' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0d7b22644cc107f7c' WHERE aws_location_name = 'us-east-2' AND pg_version = '16' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0aec02d3a6ee785eb' WHERE aws_location_name = 'ap-southeast-2' AND pg_version = '16' AND arch = 'x64';

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0146f517ef96a236b' WHERE aws_location_name = 'us-west-2' AND pg_version = '17' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0c983c025438aacd5' WHERE aws_location_name = 'us-east-1' AND pg_version = '17' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-07b914864bc47798c' WHERE aws_location_name = 'us-east-2' AND pg_version = '17' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0ecfc07de00637f25' WHERE aws_location_name = 'ap-southeast-2' AND pg_version = '17' AND arch = 'x64';

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-08d241ef2c43bd58d' WHERE aws_location_name = 'us-west-2' AND pg_version = '16' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0209475e8298c63b3' WHERE aws_location_name = 'us-east-1' AND pg_version = '16' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-07324c2c6f7307040' WHERE aws_location_name = 'us-east-2' AND pg_version = '16' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0485aad6f306cc719' WHERE aws_location_name = 'ap-southeast-2' AND pg_version = '16' AND arch = 'arm64';

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0a8ac3994a2e84490' WHERE aws_location_name = 'us-west-2' AND pg_version = '17' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-076ab55b352bf0542' WHERE aws_location_name = 'us-east-1' AND pg_version = '17' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-05e078647d2147c95' WHERE aws_location_name = 'us-east-2' AND pg_version = '17' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0189c92fdb172fb82' WHERE aws_location_name = 'ap-southeast-2' AND pg_version = '17' AND arch = 'arm64';
    SQL
  end
end
