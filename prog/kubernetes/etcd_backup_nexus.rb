# frozen_string_literal: true

class Prog::Kubernetes::EtcdBackupNexus < Prog::Base
  subject_is :kubernetes_etcd_backup

  def self.assemble(kubernetes_cluster_id)
    unless (kc = KubernetesCluster[kubernetes_cluster_id])
      fail "KubernetesCluster does not exist"
    end

    DB.transaction do
      keb = KubernetesEtcdBackup.create(
        kubernetes_cluster_id: kc.id,
        access_key: SecureRandom.hex(16),
        secret_key: SecureRandom.hex(32),
        location_id: kc.location.id
      )
      Strand.create_with_id(keb, prog: "Kubernetes::EtcdBackupNexus", label: "setup_blob_storage")
    end
  end

  def kubernetes_cluster
    @kubernetes_cluster ||= kubernetes_etcd_backup.kubernetes_cluster
  end

  label def setup_blob_storage
    nap 60 unless kubernetes_etcd_backup.blob_storage

    admin_client.admin_add_user(kubernetes_etcd_backup.access_key, kubernetes_etcd_backup.secret_key)
    admin_client.admin_policy_add(kubernetes_etcd_backup.ubid, kubernetes_etcd_backup.blob_storage_policy)
    admin_client.admin_policy_set(kubernetes_etcd_backup.ubid, kubernetes_etcd_backup.access_key)

    hop_setup_bucket
  end

  label def setup_bucket
    kubernetes_etcd_backup.setup_bucket

    hop_wait
  end

  label def wait
    if kubernetes_etcd_backup.need_backup?
      hop_run_backup
    end

    nap (kubernetes_etcd_backup.next_backup_time - Time.now + 1).clamp(1, 3601)
  end

  label def run_backup
    nap 20 * 60 unless kubernetes_cluster.strand.label == "wait"

    kubernetes_etcd_backup.update(latest_backup_started_at: Time.now)

    sshable = kubernetes_cluster.sshable
    creds = {
      "access_key" => kubernetes_etcd_backup.access_key,
      "secret_key" => kubernetes_etcd_backup.secret_key,
      "endpoint" => kubernetes_etcd_backup.blob_storage_endpoint,
      "bucket" => kubernetes_etcd_backup.ubid,
      "root_certs" => kubernetes_etcd_backup.blob_storage.root_certs
    }
    sshable.d_run("backup_etcd", "kubernetes/bin/backup-etcd", stdin: JSON.generate(creds), log: false)

    hop_wait
  end

  label def destroy
    register_deadline(nil, 5 * 60)
    decr_destroy
    # Reason for the followiwng "if" is that the MinioCluster might
    # be destroyed before this logic and it would cause nil reference exeception
    if kubernetes_etcd_backup.blob_storage
      admin_client.admin_remove_user(kubernetes_etcd_backup.access_key)
      admin_client.admin_policy_remove(kubernetes_etcd_backup.ubid)
    end

    kubernetes_etcd_backup.destroy
    pop "kubernetes etcd backup is deleted"
  end

  def admin_client
    @admin_client ||= Minio::Client.new(
      endpoint: kubernetes_etcd_backup.blob_storage_endpoint,
      access_key: kubernetes_etcd_backup.blob_storage.admin_user,
      secret_key: kubernetes_etcd_backup.blob_storage.admin_password,
      ssl_ca_data: kubernetes_etcd_backup.blob_storage.root_certs
    )
  end
end
