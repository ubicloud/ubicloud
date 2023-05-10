# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::ConfigureMinio do
  subject(:cm) { described_class.new(Strand.new(stack: [{minio_node_id: "bogus"}])) }

  describe "#start" do
    it "completes, after configuring the node with minio opts" do
      minio_cluster = instance_double(MinioCluster)
      minio_pool = instance_double(MinioPool)
      minio_node = instance_double(MinioNode)
      sshable = instance_double(Sshable)

      expect(minio_node).to receive(:minio_cluster).and_return(minio_cluster).at_least(:thrice)

      expect(minio_pool).to receive(:start_index).and_return(7).at_least(:twice)
      expect(minio_pool).to receive(:node_count).and_return(3)

      expect(minio_cluster).to receive(:admin_user).and_return("testuser")
      expect(minio_cluster).to receive(:admin_password).and_return("testpass")
      expect(minio_cluster).to receive(:name).and_return("dummy")
      expect(minio_cluster).to receive(:minio_pool).and_return([minio_pool])
      expect(minio_cluster).to receive(:minio_node).and_return([minio_node, minio_node])
      expect(minio_cluster).to receive(:generate_etc_hosts_entry).and_return("dummy7")

      expect(cm).to receive(:minio_node).and_return(minio_node).at_least(:thrice)
      expect(minio_node).to receive(:sshable).and_return(sshable)

      expect(sshable).to receive(:cmd).with(<<SH)
set -euo pipefail
sudo sh -c 'echo "MINIO_VOLUMES="http://dummy{7...9}.#{Config.minio_host_name}:9000/storage/minio"" > /etc/default/minio'
echo 'MINIO_OPTS="--console-address :9001"' | sudo tee -a /etc/default/minio
sudo sh -c 'echo "MINIO_ROOT_USER="testuser"" >> /etc/default/minio'
sudo sh -c 'echo "MINIO_ROOT_PASSWORD="testpass"" >> /etc/default/minio'
echo 'MINIO_SECRET_KEY="12345678"' | sudo tee -a /etc/default/minio
echo 'MINIO_ACCESS_KEY="minioadmin"' | sudo tee -a /etc/default/minio
echo "dummy7" | sudo tee -a /etc/hosts
SH
      expect(cm).to receive(:pop).with("configured minio node")
      cm.start
    end
  end
end
