# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO pg_aws_ami (id, aws_location_name, arch, pg_version, aws_ami_id) VALUES
        ('3a955298-cdfb-8dda-a9a7-aa23a4c34a16', 'us-east-1', 'x64', '16', 'ami-0a3297ad5c0f9f98f'),
        ('80f21c09-2db9-85da-80cf-d2e7c529f232', 'us-east-1', 'x64', '17', 'ami-0a3297ad5c0f9f98f'),
        ('cf8641fa-8e7e-85da-987e-bdc5e4f4df8f', 'us-east-1', 'arm64', '16', 'ami-0bb80e22adc550c26'),
        ('442f47e9-af22-85da-a018-9db40a1abdc9', 'us-east-1', 'arm64', '17', 'ami-0bb80e22adc550c26'),
        ('1acd752a-faa8-89da-9c09-c1c197d14211', 'us-east-2', 'x64', '16', 'ami-02d0ef7e8ed41ca48'),
        ('1dd51bbc-1a56-89da-a51f-41e248b12c33', 'us-east-2', 'x64', '17', 'ami-02d0ef7e8ed41ca48'),
        ('2b496868-042a-85da-99f7-3f847fb28573', 'us-east-2', 'arm64', '16', 'ami-04226de158be1d778'),
        ('909f3a12-f693-89da-ac57-dd16bab9fda8', 'us-east-2', 'arm64', '17', 'ami-04226de158be1d778')
      ON CONFLICT DO NOTHING;
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM pg_aws_ami WHERE id IN (
        '3a955298-cdfb-8dda-a9a7-aa23a4c34a16',
        '80f21c09-2db9-85da-80cf-d2e7c529f232',
        'cf8641fa-8e7e-85da-987e-bdc5e4f4df8f',
        '442f47e9-af22-85da-a018-9db40a1abdc9',
        '1acd752a-faa8-89da-9c09-c1c197d14211',
        '1dd51bbc-1a56-89da-a51f-41e248b12c33',
        '2b496868-042a-85da-99f7-3f847fb28573',
        '909f3a12-f693-89da-ac57-dd16bab9fda8'
      );
    SQL
  end
end
