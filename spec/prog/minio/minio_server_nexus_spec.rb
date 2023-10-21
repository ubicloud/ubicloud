# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Minio::MinioServerNexus do
  subject(:nx) { described_class.new(described_class.assemble(minio_pool.id, 0)) }

  let(:minio_pool) {
    mc = MinioCluster.create_with_id(
      location: "hetzner-hel1",
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      target_total_storage_size_gib: 100,
      target_total_pool_count: 1,
      target_total_server_count: 1,
      target_total_driver_count: 1,
      target_vm_size: "standard-2",
      private_subnet_id: ps.id
    )

    MinioPool.create_with_id(
      start_index: 0,
      cluster_id: mc.id
    )
  }
  let(:ps) {
    Prog::Vnet::SubnetNexus.assemble(
      minio_project.id, name: "minio-cluster-name"
    )
  }

  let(:minio_project) { Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) } }

  before do
    allow(Config).to receive(:minio_service_project_id).and_return(minio_project.id)
  end

  describe ".cluster" do
    it "returns minio cluster" do
      expect(nx.cluster).to eq minio_pool.cluster
    end
  end

  describe ".assemble" do
    it "creates a vm and minio server" do
      st = described_class.assemble(minio_pool.id, 0)
      expect(MinioServer.count).to eq 1
      expect(st.label).to eq "start"
      expect(MinioServer.first.pool).to eq minio_pool
      expect(Vm.count).to eq 1
      expect(Vm.first.vm_storage_volumes.count).to eq 2
      expect(Vm.first.unix_user).to eq "minio-user"
      expect(Vm.first.sshable.host).to eq "temp_#{Vm.first.id}"
      expect(Vm.first.private_subnets.first.id).to eq ps.id
    end

    it "fails if pool is not valid" do
      expect {
        described_class.assemble(SecureRandom.uuid, 0)
      }.to raise_error RuntimeError, "No existing pool"
    end
  end

  describe "#start" do
    it "nap 5 sec until VM is up and running" do
      expect { nx.start }.to nap(5)
    end

    it "updates sshable and hops to bootstrap_rhizome" do
      vm = nx.minio_server.vm
      vm.strand.update(label: "wait")
      expect(nx).to receive(:register_deadline)
      expect(vm).to receive(:ephemeral_net4).and_return("1.1.1.1")
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "minio", "subject_id" => vm.id, "user" => "minio-user"})
      expect { nx.start }.to hop("wait_bootstrap_rhizome")
      expect(vm.sshable.host).to eq "1.1.1.1"
    end
  end

  describe "#wait_bootstrap_rhizome" do
    before { expect(nx).to receive(:reap) }

    it "donates if bootstrap rhizome continues" do
      expect(nx).to receive(:leaf?).and_return(false)
      expect(nx).to receive(:donate).and_call_original
      expect { nx.wait_bootstrap_rhizome }.to nap(0)
    end

    it "hops to setup if bootstrap rhizome is done" do
      expect(nx).to receive(:leaf?).and_return(true)
      expect { nx.wait_bootstrap_rhizome }.to hop("setup")
    end
  end

  describe "#setup" do
    it "buds minio setup and hops to wait_setup" do
      expect(nx).to receive(:bud).with(Prog::Minio::SetupMinio, {}, :mount_data_disks)
      expect(nx).to receive(:bud).with(Prog::Minio::SetupMinio, {}, :install_minio)
      expect(nx).to receive(:bud).with(Prog::Minio::SetupMinio, {}, :configure_minio)
      expect { nx.setup }.to hop("wait_setup")
    end
  end

  describe "#wait_setup" do
    before { expect(nx).to receive(:reap) }

    it "donates if setup continues" do
      expect(nx).to receive(:leaf?).and_return(false)
      expect(nx).to receive(:donate).and_call_original
      expect { nx.wait_setup }.to nap(0)
    end

    it "hops to minio_start if setup is done" do
      expect(nx).to receive(:leaf?).and_return(true)
      expect { nx.wait_setup }.to hop("minio_start")
    end
  end

  describe "#minio_start" do
    it "hops to wait if succeeded" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check start_minio").and_return("Succeeded")
      expect { nx.minio_start }.to hop("wait")
    end

    it "naps if minio is not started" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check start_minio").and_return("NotStarted")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'systemctl start minio' start_minio")
      expect { nx.minio_start }.to nap(5)
    end

    it "naps if minio is failed" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check start_minio").and_return("Failed")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'systemctl start minio' start_minio")
      expect { nx.minio_start }.to nap(5)
    end

    it "naps if the status is unknown" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check start_minio").and_return("Unknown")
      expect { nx.minio_start }.to nap(5)
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(10)
    end
  end

  describe "#destroy" do
    it "triggers vm destroy, nic, sshable and minio server destroy" do
      expect(nx).to receive(:register_deadline).with(nil, 10 * 60)
      expect(nx).to receive(:decr_destroy)
      expect(nx.minio_server.vm.sshable).to receive(:destroy)
      expect(nx.minio_server.vm.nics.first).to receive(:incr_destroy)
      expect(nx.minio_server.vm).to receive(:incr_destroy)
      expect(nx.minio_server).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "minio server destroyed"})
    end
  end

  describe "#before_run" do
    it "hops to destroy if strand is not destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if strand is destroy" do
      nx.strand.update(label: "destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if destroy is not set" do
      expect(nx).to receive(:when_destroy_set?).and_return(false)
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if strand label is destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end
end
