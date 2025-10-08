# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO provider (name) VALUES ('ubicloud');
    SQL

    run <<~SQL
    INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
      ('ubicloud', 'tr-ist-u1', 'tr-ist-u1', 'Türkiye', false, '8701c4ed-bd32-4a49-9fd0-b552c7d6d73f'),
      ('ubicloud', 'tr-ist-u1-tom', 'tr-ist-u1-tom', 'Türkiye (TOM)', false, 'f03eed1b-2d59-4509-a2b1-98fe7021948a');
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM location WHERE id in ('8701c4ed-bd32-4a49-9fd0-b552c7d6d73f', 'f03eed1b-2d59-4509-a2b1-98fe7021948a');
    SQL

    run <<~SQL
      DELETE FROM provider WHERE name = 'ubicloud';
    SQL
  end
end
