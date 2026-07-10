# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
        -- gcp-europe-west3 (UBID: 102crmxx0tx24mkkz80554fg1s)
        ('gcp', 'europe-west3', 'gcp-europe-west3', 'Frankfurt, Germany (GCP)', false, '13314ef4-1ae8-8820-a4e7-f400a523e01c');
    SQL
  end

  down do
    from(:location).where(id: "13314ef4-1ae8-8820-a4e7-f400a523e01c").delete
  end
end
