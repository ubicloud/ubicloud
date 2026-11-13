# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO semaphore (id, strand_id, name)
      SELECT gen_timestamp_ubid_uuid(820), pr.id, 'use_different_az'
      FROM postgres_resource pr
      JOIN location l ON l.id = pr.location_id
      JOIN strand s ON s.id = pr.id
      WHERE l.provider = 'gcp'
        AND NOT EXISTS (
          SELECT 1 FROM semaphore
          WHERE semaphore.strand_id = pr.id AND semaphore.name = 'use_different_az'
        );
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM semaphore
      WHERE name = 'use_different_az'
        AND strand_id IN (
          SELECT pr.id FROM postgres_resource pr
          JOIN location l ON l.id = pr.location_id
          WHERE l.provider = 'gcp'
        );
    SQL
  end
end
