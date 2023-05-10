# frozen_string_literal: true

class Prog::ConfigureMinio < Prog::Base
  subject_is :minio_node

  def start
    minio_node.sshable.cmd(<<SH)
set -euo pipefail
sudo sh -c 'echo "MINIO_VOLUMES="#{minio_volumes}"" > /etc/default/minio'
echo 'MINIO_OPTS="--console-address :9001"' | sudo tee -a /etc/default/minio
sudo sh -c 'echo "MINIO_ROOT_USER="#{minio_node.minio_cluster.admin_user}"" >> /etc/default/minio'
sudo sh -c 'echo "MINIO_ROOT_PASSWORD="#{minio_node.minio_cluster.admin_password}"" >> /etc/default/minio'
echo 'MINIO_SECRET_KEY="12345678"' | sudo tee -a /etc/default/minio
echo 'MINIO_ACCESS_KEY="minioadmin"' | sudo tee -a /etc/default/minio
echo "#{minio_cluster.generate_etc_hosts_entry}" | sudo tee -a /etc/hosts
SH
    pop "configured minio node"
  end

  def minio_cluster
    @minio_cluster ||= minio_node.minio_cluster
  end

  def minio_volumes
    return "/storage/minio" if minio_cluster.minio_node.count == 1
    minio_cluster.minio_pool.map do |pool|
      "http://#{minio_cluster.name}{#{pool.start_index}...#{pool.node_count + pool.start_index - 1}}.#{Config.minio_host_name}:9000/storage/minio"
    end.join(" ")
  end
end
