# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:project) do
      set_column_default :runner_core_limit, 150
    end

    run "UPDATE project SET runner_core_limit = runner_core_limit / 2"
  end

  down do
    alter_table(:project) do
      set_column_default :runner_core_limit, 300
    end

    run "UPDATE project SET runner_core_limit = runner_core_limit * 2"
  end
end
