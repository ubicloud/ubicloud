# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:app_resource) do
      add_foreign_key :load_balancer_id, :load_balancer, type: :uuid
    end
  end
end
