# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::PostgresServerNexus do
  subject(:nx) { described_class.new(Strand.new(id: "0d77964d-c416-8edb-9237-7e7dd5d6fcf8")) }

  let(:postgres_server) {
    instance_double(
      PostgresServer,
      resource: instance_double(
        PostgresResource,
        server_cert: "server_cert",
        server_cert_key: "server_cert_key",
        superuser_password: "dummy-password"
      ),
      vm: instance_double(
        Vm,
        id: "1c7d59ee-8d46-8374-9553-6144490ecec5",
        sshable: sshable,
        ephemeral_net4: "1.1.1.1"
      )
    )
  }

  let(:sshable) { instance_double(Sshable) }

  before do
    allow(nx).to receive(:postgres_server).and_return(postgres_server)
  end

  describe ".assemble" do
    it "creates postgres server and vm with sshable" do
      postgres_resource = PostgresResource.create_with_id(
        project_id: "e3e333dd-bd9a-82d2-acc1-1c7c1ee9781f",
        location: "hetzner-hel1",
        server_name: "pg-server-name",
        target_vm_size: "standard-2",
        target_storage_size_gib: 100,
        superuser_password: "dummy-password"
      )

      postgres_project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)

      st = described_class.assemble(resource_id: postgres_resource.id)

      postgres_server = PostgresServer[st.id]
      expect(postgres_server).not_to be_nil
      expect(postgres_server.vm).not_to be_nil
      expect(postgres_server.vm.sshable).not_to be_nil
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
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
      expect(postgres_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "prep"))
      expect { nx.start }.to nap(5)
    end

    it "update sshable host and hops" do
      expect(postgres_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(postgres_server).to receive(:incr_initial_provisioning)
      expect { nx.start }.to hop("bootstrap_rhizome")
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds a bootstrap rhizome process" do
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "postgres", "subject_id" => postgres_server.vm.id, "user" => "ubi"})
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
      expect(postgres_server.vm).to receive(:vm_storage_volumes).and_return([instance_double(VmStorageVolume, boot: true, device_path: "/dev/vda"), instance_double(VmStorageVolume, boot: false, device_path: "/dev/vdb")]).twice
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
      expect(postgres_server.vm).to receive(:vm_storage_volumes).and_return([instance_double(VmStorageVolume, boot: true, device_path: "/dev/vda"), instance_double(VmStorageVolume, boot: false, device_path: "/dev/vdb")])
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

    it "hops to refresh_certificates if install_postgres command is succeeded" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check install_postgres").and_return("Succeeded")
      expect { nx.install_postgres }.to hop("refresh_certificates")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check install_postgres").and_return("Unknown")
      expect { nx.install_postgres }.to nap(5)
    end
  end

  describe "#refresh_certificates" do
    it "pushes certificates to vm and hops to configure during initial provisioning" do
      expect(sshable).to receive(:cmd).with("sudo -u postgres tee /var/lib/postgresql/16/main/server.crt > /dev/null", stdin: "server_cert")
      expect(sshable).to receive(:cmd).with("sudo -u postgres tee /var/lib/postgresql/16/main/server.key > /dev/null", stdin: "server_cert_key")
      expect(sshable).to receive(:cmd).with("sudo -u postgres chmod 600 /var/lib/postgresql/16/main/server.key")
      expect(sshable).to receive(:cmd).with("sudo -u postgres pg_ctlcluster 16 main reload")

      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect { nx.refresh_certificates }.to hop("configure")
    end

    it "hops to wait at times other than the initial provisioning" do
      expect(sshable).to receive(:cmd).at_least(:once)
      expect { nx.refresh_certificates }.to hop("wait")
    end
  end

  describe "#configure" do
    it "triggers configure if configure command is not sent yet or failed" do
      expect(postgres_server).to receive(:configure_hash).and_return("dummy-configure-hash").twice
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo postgres/bin/configure' configure_postgres", stdin: JSON.generate("dummy-configure-hash")).twice

      # NotStarted
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_postgres").and_return("NotStarted")
      expect { nx.configure }.to nap(5)

      # Failed
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_postgres").and_return("Failed")
      expect { nx.configure }.to nap(5)
    end

    it "hops to update_superuser_password if configure command is succeeded during the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_postgres").and_return("Succeeded")
      expect { nx.configure }.to hop("update_superuser_password")
    end

    it "hops to wait if configure command is succeeded at times other than the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_postgres").and_return("Succeeded")
      expect { nx.configure }.to hop("wait")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_postgres").and_return("Unknown")
      expect { nx.configure }.to nap(5)
    end
  end

  describe "#update_superuser_password" do
    it "updates password and hops to restart during the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(sshable).to receive(:cmd).with("sudo -u postgres psql", stdin: /log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      expect { nx.update_superuser_password }.to hop("restart")
    end

    it "updates password and hops to wait at times other than the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?)
      expect(sshable).to receive(:cmd).with("sudo -u postgres psql", stdin: /log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      expect { nx.update_superuser_password }.to hop("wait")
    end
  end

  describe "#restart" do
    it "restarts and hops to wait" do
      expect(sshable).to receive(:cmd).with("sudo postgres/bin/restart")
      expect { nx.restart }.to hop("wait")
    end

    it "during the initial provisioning decrements initial_provisioning semaphore" do
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(nx).to receive(:decr_initial_provisioning)
      expect(sshable).to receive(:cmd).with("sudo postgres/bin/restart")
      expect { nx.restart }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(30)
    end

    it "hops to refresh_certificates if refresh_certificates is set" do
      expect(nx).to receive(:when_refresh_certificates_set?).and_yield
      expect { nx.wait }.to hop("refresh_certificates")
    end
  end

  describe "#destroy" do
    it "waits vm deletion" do
      expect(postgres_server.vm).to receive(:private_subnets).and_return([])
      expect(postgres_server.vm).to receive(:incr_destroy)
      expect(postgres_server).not_to receive(:destroy)

      expect { nx.destroy }.to nap(5)
    end

    it "if vm is deleted destroys the entity and exits" do
      expect(postgres_server).to receive(:vm).and_return(nil)
      expect(postgres_server).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "postgres server is deleted"})
    end
  end
end
