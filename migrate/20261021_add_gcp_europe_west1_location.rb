# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
        -- gcp-europe-west1 (UBID: 10y7ney1wf8t2jp2sd6902earj)
        ('gcp', 'europe-west1', 'gcp-europe-west1', 'Belgium (GCP)', false, 'f1eaef07-8f46-8420-9585-969920139589');
    SQL
  end

  down do
    from(:location).where(id: "f1eaef07-8f46-8420-9585-969920139589").delete
  end
end
