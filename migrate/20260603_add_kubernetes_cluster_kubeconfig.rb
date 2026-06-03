# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:kubernetes_cluster) do
      add_column :kubeconfig, :text, collate: '"C"'
    end
  end
end
