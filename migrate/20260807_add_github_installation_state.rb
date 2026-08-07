# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:github_installation) do
      add_column :state, :text, collate: '"C"', default: "active", null: false
      add_constraint :github_installation_state_check, "state IN ('active', 'deleting')"
    end

    installation_ids = from(:strand)
      .where(prog: "Github::DestroyGithubInstallation")
      .select_map(:stack)
      .flat_map { |stack| Array(stack).filter_map { it["subject_id"] } }
      .uniq
    from(:github_installation).where(id: installation_ids).update(state: "deleting") unless installation_ids.empty?
  end

  down do
    alter_table(:github_installation) do
      drop_column :state
    end
  end
end
