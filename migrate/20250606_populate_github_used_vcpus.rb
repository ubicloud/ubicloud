# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      UPDATE github_installation
      SET used_vcpus = runner_sum.total_vcpus
      FROM (
        SELECT
          installation_id,
          SUM(
            CASE
              WHEN label = 'ubicloud' THEN 2
              WHEN label = 'ubicloud-arm' THEN 2
              WHEN label = 'ubicloud-gpu' THEN 6
              ELSE REGEXP_REPLACE(label, '^.*(?:standard|premium)-(\\d+).*$', '\\1')::INT
            END
          ) AS total_vcpus
          FROM github_runner
          GROUP BY installation_id
      ) AS runner_sum
      WHERE github_installation.id = runner_sum.installation_id;
    SQL

    alter_table(:github_installation) do
      add_constraint(:used_vcpus_not_negative) { used_vcpus >= 0 }
    end
  end

  down do
    alter_table(:github_installation) do
      drop_constraint(:used_vcpus_not_negative)
    end
  end
end
