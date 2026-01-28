# frozen_string_literal: true

class Prog::Test::MinioCluster < Prog::Test::Base
  semaphore :destroy_and_verify

  def self.assemble(project_id)
    Project[Config.minio_service_project_id] ||
      Project.create_with_id(Config.minio_service_project_id, name: "Minio-Service-Project")

    Strand.create(
      prog: "Test::MinioCluster",
      label: "start",
      stack: [{"project_id" => project_id}]
    )
  end

  label def start
    minio_cluster = Prog::Minio::MinioClusterNexus.assemble(
      frame["project_id"],
      "postgres-minio-e2e",
      Location::HETZNER_FSN1_ID, "minio-admin", 32, 1, 1, 1, "standard-2"
    ).subject
    update_stack({"minio_cluster_id" => minio_cluster.id})
    hop_wait
  end

  label def wait
    hop_trigger_destroy if destroy_and_verify_set?
    nap 10
  end

  label def trigger_destroy
    minio_cluster.incr_destroy
    hop_wait_destroy
  end

  label def wait_destroy
    nap 5 if minio_cluster
    pop "MinIO cluster destroyed"
  end

  label def failed
    nap 15
  end

  def minio_cluster
    @minio_cluster ||= MinioCluster[frame["minio_cluster_id"]]
  end
end
