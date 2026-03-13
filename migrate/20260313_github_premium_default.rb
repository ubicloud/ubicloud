# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:github_installation) do
      set_column_default(:allocator_preferences, '{"family_filter": ["premium", "standard"]}')
    end
  end

  down do
    alter_table(:github_installation) do
      set_column_default(:allocator_preferences, "{}")
    end
  end
end
