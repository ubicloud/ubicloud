# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO pg_aws_ami (id, aws_location_name, arch, pg_version, family, aws_ami_id)
      SELECT gen_random_ubid_uuid(474), aws_location_name, arch, '19', family, aws_ami_id
      FROM pg_aws_ami WHERE pg_version = '18';

      UPDATE pg_gce_image SET pg_versions = array_append(pg_versions, '19') WHERE '18' = ANY(pg_versions);
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM pg_aws_ami WHERE pg_version = '19';

      UPDATE pg_gce_image SET pg_versions = array_remove(pg_versions, '19');
    SQL
  end
end
