# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:github_runner) do
      add_column :actual_label, :text, collate: '"C"', null: true
    end

    # Update existing runners to set actual_label to their current label
    run "UPDATE github_runner SET actual_label = label"
  end

  down do
    alter_table(:github_runner) do
      drop_column :actual_label
    end
  end
end
