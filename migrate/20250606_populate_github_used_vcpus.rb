# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      UPDATE github_installation
      SET used_vcpus_x64 = runner_sum.total_vcpus
      FROM (
        SELECT
          installation_id,
          SUM(
            CASE
              WHEN label = 'ubicloud' THEN 2
              WHEN label = 'ubicloud-gpu' THEN 6
              ELSE REGEXP_REPLACE(label, '^.*(?:standard|premium)-(\d+).*$', '\1')::INT
            END
          ) AS total_vcpus
          FROM github_runner
          WHERE label NOT LIKE '%arm%'
          GROUP BY installation_id
      ) AS runner_sum
      WHERE github_installation.id = runner_sum.installation_id;
    SQL

    run <<~SQL
      UPDATE github_installation
      SET used_vcpus_arm64 = runner_sum.total_vcpus
      FROM (
        SELECT
          installation_id,
          SUM(
            CASE
              WHEN label = 'ubicloud-arm' THEN 2
              ELSE REGEXP_REPLACE(label, '^.*(?:standard|premium)-(\d+).*$', '\1')::INT
            END
          ) AS total_vcpus
          FROM github_runner
          WHERE label LIKE '%arm%'
          GROUP BY installation_id
      ) AS runner_sum
      WHERE github_installation.id = runner_sum.installation_id;
    SQL

    alter_table(:github_installation) do
      add_constraint(:used_vcpus_x64_not_negative) { used_vcpus_x64 >= 0 }
      add_constraint(:used_vcpus_arm64_not_negative) { used_vcpus_arm64 >= 0 }
    end
  end

  down do
    alter_table(:github_installation) do
      drop_constraint(:used_vcpus_x64_not_negative)
      drop_constraint(:used_vcpus_arm64_not_negative)
    end
  end
end
