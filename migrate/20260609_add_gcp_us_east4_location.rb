# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
        -- gcp-us-east4 (UBID: 10f49zfetffy5q8h968ywxzmc0)
        ('gcp', 'us-east4', 'gcp-us-east4', 'Virginia, US (GCP)', false, '7913f7bb-4f7f-8820-ba22-9323dcefe8c0');
    SQL
  end

  down do
    from(:location).where(id: "7913f7bb-4f7f-8820-ba22-9323dcefe8c0").delete
  end
end
