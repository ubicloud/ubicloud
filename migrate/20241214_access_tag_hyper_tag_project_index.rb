# frozen_string_literal: true

Sequel.migration do
  # CREATE INDEX CONCURRENTLY is not supported inside transactions
  no_transaction

  change do
    add_index :access_tag, [:hyper_tag_id, :project_id],
      name: :access_tag_hyper_tag_id_project_id_index,
      concurrently: true
  end
end
