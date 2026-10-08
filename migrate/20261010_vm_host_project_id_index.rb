# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :vm_host, :project_id, where: Sequel.~(project_id: nil), concurrently: true
  end
end
