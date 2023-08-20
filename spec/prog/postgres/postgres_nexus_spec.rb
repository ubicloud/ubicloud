# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::PostgresNexus do
  subject(:nx) { described_class.new(Strand.new(id: PostgresServer.generate_uuid)) }

  let(:project) { Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) } }

  let(:postgres_server) { instance_double(PostgresServer, id: "0eb058bb-960e-46fe-aab7-3717f164ab25", project_id: project.id, server_name: "pg-server-name", location: "hetzner-hel1", target_storage_size_gib: 100) }
  let(:vm) { instance_double(Vm, id: "788525ed-d6f0-4937-a844-323d4fd91946", cores: 1) }
  let(:sshable) { instance_double(Sshable) }

  before do
    allow(vm).to receive(:sshable).and_return(sshable)
    allow(postgres_server).to receive_messages(project: project, vm: vm)
    allow(nx).to receive(:postgres_server).and_return(postgres_server)
  end

  describe ".assemble" do
    let(:postgres_project) { Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) } }

    before do
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    end

    it "validates input" do
      expect {
        described_class.assemble(SecureRandom.uuid, "hetzner-hel1", "pg-server-name", "standard-2", 100)
      }.to raise_error RuntimeError, "No existing project"

      expect {
        described_class.assemble(project.id, "hetzner-xxx", "pg-server-name", "standard-2", 100)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: provider"

      expect {
        described_class.assemble(project.id, "hetzner-hel1", "pg/server/name", "standard-2", 100)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(project.id, "hetzner-hel1", "pg-server-name", "standard-128", 100)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: size"
    end

    it "creates postgres server and vm with sshable" do
      st = described_class.assemble(project.id, "hetzner-hel1", "pg-server-name", "standard-2", 100)

      postgres_server = PostgresServer[st.id]
      expect(postgres_server).not_to be_nil
      expect(postgres_server.vm).not_to be_nil
      expect(postgres_server.vm.sshable).not_to be_nil
    end
  end

  describe "#before_run" do
    it "hops to destroy and stops billing records when needed" do
      br = instance_double(BillingRecord)
      expect(br).to receive(:finalize).twice
      expect(postgres_server).to receive(:active_billing_records).and_return([br, br])
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "naps if vm not ready" do
      expect(vm).to receive(:strand).and_return(Strand.new(label: "prep"))
      expect { nx.start }.to nap(5)
    end

    it "update sshable host and hops" do
      expect(postgres_server).to receive(:incr_initial_provisioning)
      expect(vm).to receive(:strand).and_return(Strand.new(label: "wait"))
      expect(vm).to receive(:ephemeral_net4).and_return("1.1.1.1")
      expect(sshable).to receive(:update).with(host: "1.1.1.1")
      expect { nx.start }.to hop("bootstrap_rhizome")
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds a bootstrap rhizome process" do
      expect(nx).to receive(:register_deadline)
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "postgres", "subject_id" => vm.id, "user" => "ubi"})
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    before { expect(nx).to receive(:reap) }

    it "hops to mount_data_disk if there are no sub-programs running" do
      expect(nx).to receive(:leaf?).and_return true

      expect { nx.wait_bootstrap_rhizome }.to hop("mount_data_disk")
    end

    it "donates if there are sub-programs running" do
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_bootstrap_rhizome }.to nap(0)
    end
  end

  describe "#mount_data_disk" do
    it "formats data disk if format command is not sent yet or failed" do
      expect(vm).to receive(:vm_storage_volumes).and_return([instance_double(VmStorageVolume, boot: true, device_path: "/dev/vda"), instance_double(VmStorageVolume, boot: false, device_path: "/dev/vdb")]).twice
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo mkfs --type ext4 /dev/vdb' format_disk").twice

      # NotStarted
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disk").and_return("NotStarted")
      expect { nx.mount_data_disk }.to nap(5)

      # Failed
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disk").and_return("Failed")
      expect { nx.mount_data_disk }.to nap(5)
    end

    it "mounts data disk if format disk is succeeded and hops to install_postgres" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disk").and_return("Succeeded")
      expect(vm).to receive(:vm_storage_volumes).and_return([instance_double(VmStorageVolume, boot: true, device_path: "/dev/vda"), instance_double(VmStorageVolume, boot: false, device_path: "/dev/vdb")])
      expect(sshable).to receive(:cmd).with("sudo mkdir -p /dat")
      expect(sshable).to receive(:cmd).with("sudo common/bin/add_to_fstab /dev/vdb /dat ext4 defaults 0 0")
      expect(sshable).to receive(:cmd).with("sudo mount /dev/vdb /dat")
      expect { nx.mount_data_disk }.to hop("install_postgres")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disk").and_return("Unknown")
      expect { nx.mount_data_disk }.to nap(5)
    end
  end

  describe "#install_postgres" do
    it "triggers install_postgres if install_postgres command is not sent yet or failed" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo postgres/bin/install_postgres' install_postgres").twice

      # NotStarted
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check install_postgres").and_return("NotStarted")
      expect { nx.install_postgres }.to nap(5)

      # Failed
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check install_postgres").and_return("Failed")
      expect { nx.install_postgres }.to nap(5)
    end

    it "hops to configure if install_postgres command is succeeded" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check install_postgres").and_return("Succeeded")
      expect { nx.install_postgres }.to hop("configure")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check install_postgres").and_return("Unknown")
      expect { nx.install_postgres }.to nap(5)
    end
  end

  describe "#configure" do
    it "triggers configure if configure command is not sent yet or failed" do
      expect(postgres_server).to receive(:configure_hash).and_return("dummy-configure-hash").twice
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo postgres/bin/configure' configure", stdin: JSON.generate("dummy-configure-hash")).twice

      # NotStarted
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure").and_return("NotStarted")
      expect { nx.configure }.to nap(5)

      # Failed
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure").and_return("Failed")
      expect { nx.configure }.to nap(5)
    end

    it "hops to restart if configure command is succeeded during the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure").and_return("Succeeded")
      expect { nx.configure }.to hop("restart")
    end

    it "hops to wait if configure command is succeeded at times other than the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure").and_return("Succeeded")
      expect { nx.configure }.to hop("wait")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure").and_return("Unknown")
      expect { nx.configure }.to nap(5)
    end
  end

  describe "#restart" do
    it "restarts and hops to create_billing_record during the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(nx).to receive(:decr_restart)
      expect(sshable).to receive(:cmd).with("sudo postgres/bin/restart")
      expect { nx.restart }.to hop("create_billing_record")
    end

    it "restarts and hops to wait at times other than the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?)
      expect(nx).to receive(:decr_restart)
      expect(sshable).to receive(:cmd).with("sudo postgres/bin/restart")
      expect { nx.restart }.to hop("wait")
    end
  end

  describe "#create_billing_record" do
    it "creates billing record for cores and storage then hops" do
      expect(nx).to receive(:decr_initial_provisioning)

      expect(BillingRecord).to receive(:create_with_id).with(
        project_id: postgres_server.project_id,
        resource_id: postgres_server.id,
        resource_name: postgres_server.server_name,
        billing_rate_id: BillingRate.from_resource_properties("PostgresCores", "standard", postgres_server.location)["id"],
        amount: vm.cores
      )

      expect(BillingRecord).to receive(:create_with_id).with(
        project_id: postgres_server.project_id,
        resource_id: postgres_server.id,
        resource_name: postgres_server.server_name,
        billing_rate_id: BillingRate.from_resource_properties("PostgresStorage", "standard", postgres_server.location)["id"],
        amount: postgres_server.target_storage_size_gib
      )

      expect { nx.create_billing_record }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "triggers vm deletion and waits until it is deleted" do
      expect(sshable).to receive(:destroy)
      expect(vm).to receive(:private_subnets).and_return([])
      expect(vm).to receive(:incr_destroy)
      expect { nx.destroy }.to nap(5)

      expect(vm).to receive(:sshable).and_return(nil)
      expect(vm).to receive(:private_subnets).and_return([])
      expect(vm).to receive(:incr_destroy)
      expect { nx.destroy }.to nap(5)

      expect(postgres_server).to receive(:vm).and_return(nil)
      expect(postgres_server).to receive(:dissociate_with_project)
      expect(postgres_server).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "postgres server is deleted"})
    end
  end
end
