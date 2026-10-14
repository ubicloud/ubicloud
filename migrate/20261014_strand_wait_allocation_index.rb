# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :strand, :id, name: :strand_wait_allocation_id_index, where: {prog: "Vm::Metal::Nexus", label: "wait_allocation", exitval: nil}, concurrently: true
  end
end
