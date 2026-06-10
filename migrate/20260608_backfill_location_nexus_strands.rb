# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO strand (id, prog, label)
      SELECT id, 'LocationNexus', 'wait'
      FROM location
      WHERE NOT EXISTS (SELECT 1 FROM strand WHERE strand.id = location.id);
    SQL
  end

  down do
    run "DELETE FROM strand WHERE prog = 'LocationNexus';"
  end
end
