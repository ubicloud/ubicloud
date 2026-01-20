# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::EtcdBackupNexus do
  subject(:nx) { described_class.new(Strand.create(id: kubernetes_etcd_backup.id, prog: "Kubernetes::EtcdBackupNexus", label: "setup_blob_storage")) }

  let(:project) { Project.create(name: "test") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }
  let(:private_subnet) { PrivateSubnet.create(project_id: project.id, name: "test", location_id: location.id, net6: "fe80::/64", net4: "192.168.0.0/24") }
  let(:kc) {
    MinioCluster.create(project_id: project.id, location_id: location.id, name: "minio-cluster", admin_user: "admin", admin_password: "password", root_cert_1: "certs")
    kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "test",
      version: Option.kubernetes_versions.first,
      location_id: location.id,
      project_id: project.id,
      private_subnet_id: private_subnet.id,
      cp_node_count: 1,
      target_node_size: "standard-2"
    ).subject
    vm = Prog::Vm::Nexus.assemble("public key", project.id, name: "cp", private_subnet_id: kc.private_subnet.id).subject
    Sshable.create_with_id(vm)
    KubernetesNode.create(vm_id: vm.id, kubernetes_cluster_id: kc.id)
    kc.strand.update(label: "wait")
    kc
  }
  let(:kubernetes_etcd_backup) {
    KubernetesEtcdBackup.create(
      kubernetes_cluster_id: kc.id,
      access_key: "access",
      secret_key: "secret",
      location_id: location.id
    )
  }

  before do
    allow(Config).to receive_messages(
      postgres_service_project_id: project.id,
      kubernetes_service_project_id: project.id
    )
    allow(nx).to receive(:kubernetes_etcd_backup).and_return(kubernetes_etcd_backup)
  end

  describe ".assemble" do
    it "throws an exception if kubernetes cluster does not exist" do
      expect {
        described_class.assemble(SecureRandom.uuid)
      }.to raise_error RuntimeError, "KubernetesCluster does not exist"
    end

    it "creates kubernetes etcd backup and strand" do
      described_class.assemble(kc.id)

      keb = KubernetesEtcdBackup.last
      strand = keb.strand
      expect(strand.prog).to eq "Kubernetes::EtcdBackupNexus"
      expect(strand.label).to eq "setup_blob_storage"
    end
  end

  describe "#setup_blob_storage" do
    let(:admin_client) { instance_double(Minio::Client) }

    it "sets up user and policy in minio and hops" do
      expect(Minio::Client).to receive(:new).and_return(admin_client)
      expect(admin_client).to receive(:admin_add_user).with(kubernetes_etcd_backup.access_key, kubernetes_etcd_backup.secret_key)
      expect(admin_client).to receive(:admin_policy_add).with(kubernetes_etcd_backup.ubid, kubernetes_etcd_backup.blob_storage_policy)
      expect(admin_client).to receive(:admin_policy_set).with(kubernetes_etcd_backup.ubid, kubernetes_etcd_backup.access_key)

      expect { nx.setup_blob_storage }.to hop("setup_bucket")
    end

    context "when blob storage is not available" do
      it "naps" do
        MinioCluster[name: "minio-cluster"].destroy
        expect(Minio::Client).not_to receive(:new)
        expect { nx.setup_blob_storage }.to nap(60)
      end
    end
  end

  describe "#setup_bucket" do
    let(:client) { instance_double(Minio::Client) }

    before do
      expect(Minio::Client).to receive(:new).with(
        endpoint: "https://minio.test",
        access_key: kubernetes_etcd_backup.access_key,
        secret_key: kubernetes_etcd_backup.secret_key,
        ssl_ca_data: kubernetes_etcd_backup.blob_storage.root_certs
      ).and_return(client)
    end

    it "calls setup_bucket on model and hops" do
      expect(kubernetes_etcd_backup.blob_storage).to receive(:url).and_return("https://minio.test")
      expect(client).to receive(:create_bucket)
      expect(client).to receive(:set_lifecycle_policy)
      expect { nx.setup_bucket }.to hop("wait")
    end
  end

  describe "#wait" do
    it "hops to run_backup if backup needed" do
      expect(kubernetes_etcd_backup.kubernetes_cluster.functional_nodes.first.vm.sshable).to receive(:d_check).with("backup_etcd").and_return("NotStarted")
      expect { nx.wait }.to hop("run_backup")
    end

    context "when backup is not needed" do
      let(:now) { Time.now }

      before do
        expect(Time).to receive(:now).and_return(now).at_least(:once)
        expect(kubernetes_etcd_backup.kubernetes_cluster.functional_nodes.first.vm.sshable).to receive(:d_check).with("backup_etcd").and_return("Succeeded")
        kubernetes_etcd_backup.update(latest_backup_started_at: Time.now)
      end

      it "naps for the difference between next_backup_time and now + 1" do
        expect(nx.kubernetes_etcd_backup).to receive(:next_backup_time).and_return(now + 1200)
        expect { nx.wait }.to nap(1201)
      end

      it "naps for at least 1 second" do
        expect(nx.kubernetes_etcd_backup).to receive(:next_backup_time).and_return(now - 100)
        expect { nx.wait }.to nap(1)
      end

      it "naps for at most 3601 seconds" do
        expect(nx.kubernetes_etcd_backup).to receive(:next_backup_time).and_return(now + 4000)
        expect { nx.wait }.to nap(3601)
      end
    end
  end

  describe "#run_backup" do
    it "naps if cluster is not in wait state" do
      kc.strand.update(label: "starting")
      expect { nx.run_backup }.to nap(20 * 60)
    end

    it "runs backup command and hops to wait" do
      kc.strand.update(label: "wait")

      creds = {
        "access_key" => kubernetes_etcd_backup.access_key,
        "secret_key" => kubernetes_etcd_backup.secret_key,
        "endpoint" => kubernetes_etcd_backup.blob_storage_endpoint,
        "bucket" => kubernetes_etcd_backup.ubid,
        "root_certs" => kubernetes_etcd_backup.blob_storage.root_certs
      }

      expect(nx.kubernetes_cluster.functional_nodes.first.vm.sshable).to receive(:d_run).with(
        "backup_etcd",
        "kubernetes/bin/backup-etcd",
        stdin: JSON.generate(creds),
        log: false
      )

      expect { nx.run_backup }.to hop("wait")
    end

    it "updates latest_backup_started_at" do
      kc.strand.update(label: "wait")

      expect(nx.kubernetes_cluster.functional_nodes.first.vm.sshable).to receive(:d_run)

      expect { nx.run_backup }.to hop("wait")
      expect(kubernetes_etcd_backup.reload.latest_backup_started_at).to be_within(1).of(Time.now)
    end
  end

  describe "#destroy" do
    let(:admin_client) { instance_double(Minio::Client) }

    it "removes user and policy from minio" do
      expect(kubernetes_etcd_backup.blob_storage).to receive(:url).and_return("https://minio.test")
      expect(Minio::Client).to receive(:new).and_return(admin_client)

      expect(admin_client).to receive(:admin_remove_user).with(kubernetes_etcd_backup.access_key)
      expect(admin_client).to receive(:admin_policy_remove).with(kubernetes_etcd_backup.ubid)

      expect { nx.destroy }.to exit({"msg" => "kubernetes etcd backup is deleted"})
    end

    context "when blob storage is missing" do
      it "does not attempt to remove user or policy and exits" do
        MinioCluster[name: "minio-cluster"].destroy
        expect(Minio::Client).not_to receive(:new)
        expect { nx.destroy }.to exit({"msg" => "kubernetes etcd backup is deleted"})
      end
    end
  end
end
