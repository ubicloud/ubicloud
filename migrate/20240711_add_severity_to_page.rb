# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:page_severity, %w[critical error warning info])

    alter_table(:page) do
      add_column :severity, :page_severity, default: "error", null: false
    end
  end
end
