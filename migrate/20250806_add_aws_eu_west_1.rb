# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO pg_aws_ami(id, aws_location_name, aws_ami_id, pg_version, arch) VALUES
        ('ef095551-8d32-81da-ad27-737d0994e7b1', 'eu-west-1', 'ami-09e89e625ae591e26', '16', 'x64'),
        ('d8bb3523-51c8-85da-98df-5524bde2dd60', 'eu-west-1', 'ami-0d15507e807d2fa3e', '16', 'arm64'),
        ('85ddf52f-471f-85da-b93c-ba3c196dfd50', 'eu-west-1', 'ami-09bd55bf95d7d1192', '17', 'x64'),
        ('4972c558-5d15-89da-a107-fa5a10ac27de', 'eu-west-1', 'ami-0371bfa81d8cbbc16', '17', 'arm64');
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM pg_aws_ami WHERE aws_location_name = 'eu-west-1';
    SQL
  end
end
