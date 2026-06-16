# frozen_string_literal: true

Sequel.migration do
  up do
    run(<<~SQL)
      INSERT INTO strand (id, prog, label)
      SELECT id, 'MachineImage::VersionMetalNexus', 'wait'
      FROM machine_image_version_metal
    SQL
  end

  down do
    run(<<~SQL)
      DELETE FROM strand
      WHERE prog = 'MachineImage::VersionMetalNexus'
    SQL
  end
end
