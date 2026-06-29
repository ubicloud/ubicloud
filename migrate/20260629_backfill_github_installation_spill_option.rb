# frozen_string_literal: true

Sequel.migration do
  up do
    # Move the spill_to_alien_runners / aws_alien_runners_ratio project feature
    # flags into a per-installation github_installation_spill_option row. An
    # installation gets a row when its project had either flag set.
    run <<~SQL
      INSERT INTO github_installation_spill_option (id, spill_ratio, vcpus_limit)
      SELECT gi.id,
             COALESCE((p.feature_flags->>'aws_alien_runners_ratio')::numeric, 0),
             300
      FROM github_installation gi
      JOIN project p ON p.id = gi.project_id
      WHERE p.feature_flags->>'spill_to_alien_runners' = 'true'
         OR jsonb_exists(p.feature_flags, 'aws_alien_runners_ratio')
    SQL

    run <<~SQL
      UPDATE project
      SET feature_flags = feature_flags - 'spill_to_alien_runners' - 'aws_alien_runners_ratio'
      WHERE jsonb_exists(feature_flags, 'spill_to_alien_runners')
         OR jsonb_exists(feature_flags, 'aws_alien_runners_ratio')
    SQL
  end

  down do
    # Intentionally no-op: the table is dropped by the companion migration, and
    # the old feature flag values are not restored.
    nil
  end
end
