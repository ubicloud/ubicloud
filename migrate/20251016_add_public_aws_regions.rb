# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
    INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
      ('aws', 'us-east-1', 'us-east-1', 'Virginia, US (AWS)', false, '0782aa80-9230-8c20-87f9-544533f2f1ce'),
      ('aws', 'us-west-2', 'us-west-2', 'Oregon, US (AWS)', false, '78b8e968-ea9c-8020-b837-e7949eb9db7f');
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM location WHERE id in ('0782aa80-9230-8c20-87f9-544533f2f1ce', '78b8e968-ea9c-8020-b837-e7949eb9db7f');
    SQL
  end
end
