# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-033db45b22ea9d5f5' WHERE aws_location_name = 'us-west-2' AND pg_version = '16' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0eb8c2917209d976c' WHERE aws_location_name = 'us-east-1' AND pg_version = '16' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0d7b22644cc107f7c' WHERE aws_location_name = 'us-east-2' AND pg_version = '16' AND arch = 'x64';

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0146f517ef96a236b' WHERE aws_location_name = 'us-west-2' AND pg_version = '17' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0c983c025438aacd5' WHERE aws_location_name = 'us-east-1' AND pg_version = '17' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-07b914864bc47798c' WHERE aws_location_name = 'us-east-2' AND pg_version = '17' AND arch = 'x64';

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-08d241ef2c43bd58d' WHERE aws_location_name = 'us-west-2' AND pg_version = '16' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0209475e8298c63b3' WHERE aws_location_name = 'us-east-1' AND pg_version = '16' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-07324c2c6f7307040' WHERE aws_location_name = 'us-east-2' AND pg_version = '16' AND arch = 'arm64';

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0a8ac3994a2e84490' WHERE aws_location_name = 'us-west-2' AND pg_version = '17' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-076ab55b352bf0542' WHERE aws_location_name = 'us-east-1' AND pg_version = '17' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-05e078647d2147c95' WHERE aws_location_name = 'us-east-2' AND pg_version = '17' AND arch = 'arm64';
    SQL

    run <<~SQL
      INSERT INTO pg_aws_ami(id, aws_location_name, aws_ami_id, pg_version, arch) VALUES
        ('9d9b87e0-f5dc-8dda-834d-d59c157b71e3', 'ap-southeast-2', 'ami-0aec02d3a6ee785eb', '16', 'x64'),
        ('3cc87ea6-f3f8-89da-a6a6-5c85415a213b', 'ap-southeast-2', 'ami-0485aad6f306cc719', '16', 'arm64'),
        ('3d18774e-1f92-8dda-afc1-b3a6643fe48f', 'ap-southeast-2', 'ami-0ecfc07de00637f25', '17', 'x64'),
        ('7da3ded3-112c-8dda-aef0-2808cf26e89d', 'ap-southeast-2', 'ami-0189c92fdb172fb82', '17', 'arm64');
    SQL
  end

  down do
    run <<~SQL
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0fa4a3d37a0340e0b' WHERE aws_location_name = 'us-west-2' AND pg_version = '16' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0be2c55a267846818' WHERE aws_location_name = 'us-east-1' AND pg_version = '16' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-05403488066ce85e5' WHERE aws_location_name = 'us-east-2' AND pg_version = '16' AND arch = 'x64';

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0dee3e51a7288abec' WHERE aws_location_name = 'us-west-2' AND pg_version = '17' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0a2be334cf2f6a94e' WHERE aws_location_name = 'us-east-1' AND pg_version = '17' AND arch = 'x64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0badeb4aed1febf46' WHERE aws_location_name = 'us-east-2' AND pg_version = '17' AND arch = 'x64';

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0d60ec66b6112a54b' WHERE aws_location_name = 'us-west-2' AND pg_version = '16' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0eb7b9f20283f461f' WHERE aws_location_name = 'us-east-1' AND pg_version = '16' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-03da875684e5bbda1' WHERE aws_location_name = 'us-east-2' AND pg_version = '16' AND arch = 'arm64';

      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0cad1682a42fef6e5' WHERE aws_location_name = 'us-west-2' AND pg_version = '17' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-0cda981a9b43cd352' WHERE aws_location_name = 'us-east-1' AND pg_version = '17' AND arch = 'arm64';
      UPDATE pg_aws_ami SET aws_ami_id = 'ami-03a0d9514e598f5c4' WHERE aws_location_name = 'us-east-2' AND pg_version = '17' AND arch = 'arm64';
    SQL

    run <<~SQL
      DELETE FROM pg_aws_ami WHERE aws_location_name = 'ap-southeast-2';
    SQL
  end
end
