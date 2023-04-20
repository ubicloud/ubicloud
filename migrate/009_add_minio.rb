Sequel.migration do
  change do
    create_table(:minio_cluster) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
    end
    create_table(:minio_node) do
      foreign_key :id, :sshable, type: :uuid, primary_key: true
      foreign_key :cluster_id, :minio_cluster, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false, unique: true
    end
  end
end