# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
    INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
      -- ubid: 1e7vvyr84s1x2kn9c6576basmz
      ('ubicloud', 'us-west-u1-ps', 'us-west-u1-ps', 'PS: SF Bay Area, US', false, '3ef7ec20-990f-442e-9d52-c314e65ab34f')
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM location WHERE id = '3ef7ec20-990f-442e-9d52-c314e65ab34f';
    SQL
  end
end
