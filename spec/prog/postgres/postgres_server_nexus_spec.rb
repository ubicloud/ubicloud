# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::PostgresServerNexus do
  subject(:nx) { described_class.new(Strand.create(id: "0d77964d-c416-8edb-9237-7e7dd5d6fcf8", prog: "Postgres::PostgresServerNexus", label: "start")) }

  let(:postgres_server) {
    instance_double(
      PostgresServer,
      ubid: "pgubid",
      timeline: instance_double(
        PostgresTimeline,
        id: "f6644aae-9759-8ada-9aef-9b6cfccdc167",
        generate_walg_config: "walg config",
        blob_storage: instance_double(MinioCluster, root_certs: "certs")
      ),
      vm: instance_double(
        Vm,
        id: "1c7d59ee-8d46-8374-9553-6144490ecec5",
        sshable: sshable,
        ephemeral_net4: "1.1.1.1"
      )
    )
  }

  let(:resource) {
    instance_double(
      PostgresResource,
      root_cert_1: "root_cert_1",
      root_cert_2: "root_cert_2",
      server_cert: "server_cert",
      server_cert_key: "server_cert_key",
      superuser_password: "dummy-password",
      representative_server: postgres_server
    )
  }

  let(:sshable) { instance_double(Sshable) }

  before do
    allow(nx).to receive(:postgres_server).and_return(postgres_server)
    allow(postgres_server).to receive(:resource).and_return(resource)
  end

  describe ".assemble" do
    it "creates postgres server and vm with sshable" do
      postgres_resource = PostgresResource.create_with_id(
        project_id: "e3e333dd-bd9a-82d2-acc1-1c7c1ee9781f",
        location: "hetzner-hel1",
        name: "pg-name",
        target_vm_size: "standard-2",
        target_storage_size_gib: 100,
        superuser_password: "dummy-password"
      )

      postgres_timeline = PostgresTimeline.create_with_id

      postgres_project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)

      st = described_class.assemble(resource_id: postgres_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", representative_at: Time.now)
      postgres_server = PostgresServer[st.id]
      expect(postgres_server).not_to be_nil
      expect(postgres_server.vm).not_to be_nil
      expect(postgres_server.vm.sshable).not_to be_nil

      st = described_class.assemble(resource_id: postgres_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push")
      expect(PostgresServer[st.id].synchronization_status).to eq("catching_up")
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

    it "mounts data disk if format disk is succeeded and hops to configure_walg_credentials" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disk").and_return("Succeeded")
      expect(postgres_server.vm).to receive(:vm_storage_volumes).and_return([instance_double(VmStorageVolume, boot: true, device_path: "/dev/vda"), instance_double(VmStorageVolume, boot: false, device_path: "/dev/vdb")])
      expect(sshable).to receive(:cmd).with("sudo mkdir -p /dat")
      expect(sshable).to receive(:cmd).with("sudo common/bin/add_to_fstab /dev/vdb /dat ext4 defaults 0 0")
      expect(sshable).to receive(:cmd).with("sudo mount /dev/vdb /dat")
      expect { nx.mount_data_disk }.to hop("configure_walg_credentials")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disk").and_return("Unknown")
      expect { nx.mount_data_disk }.to nap(5)
    end
  end

  describe "#configure_walg_credentials" do
    it "hops to initialize_empty_database if the server is primary" do
      expect(sshable).to receive(:cmd).with("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: "walg config")
      expect(sshable).to receive(:cmd).with("sudo tee /usr/lib/ssl/certs/blob_storage_ca.crt > /dev/null", stdin: "certs")
      expect(postgres_server).to receive(:primary?).and_return(true)

      expect { nx.configure_walg_credentials }.to hop("initialize_empty_database")
    end

    it "hops to initialize_database_from_backup if the server is not primary" do
      expect(sshable).to receive(:cmd).with("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: "walg config")
      expect(sshable).to receive(:cmd).with("sudo tee /usr/lib/ssl/certs/blob_storage_ca.crt > /dev/null", stdin: "certs")
      expect(postgres_server).to receive(:primary?).and_return(false)
      expect { nx.configure_walg_credentials }.to hop("initialize_database_from_backup")
    end
  end

  describe "#initialize_empty_database" do
    it "triggers initialize_empty_database if initialize_empty_database command is not sent yet or failed" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo postgres/bin/initialize-empty-database' initialize_empty_database").twice

      # NotStarted
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check initialize_empty_database").and_return("NotStarted")
      expect { nx.initialize_empty_database }.to nap(5)

      # Failed
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check initialize_empty_database").and_return("Failed")
      expect { nx.initialize_empty_database }.to nap(5)
    end

    it "hops to refresh_certificates if initialize_empty_database command is succeeded" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check initialize_empty_database").and_return("Succeeded")
      expect { nx.initialize_empty_database }.to hop("refresh_certificates")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check initialize_empty_database").and_return("Unknown")
      expect { nx.initialize_empty_database }.to nap(5)
    end
  end

  describe "#initialize_database_from_backup" do
    it "triggers initialize_database_from_backup if initialize_database_from_backup command is not sent yet or failed" do
      expect(postgres_server.resource).to receive(:restore_target).and_return(Time.now).twice
      expect(postgres_server.timeline).to receive(:latest_backup_label_before_target).and_return("backup-label").twice
      expect(postgres_server).to receive(:standby?).and_return(false).twice
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo postgres/bin/initialize-database-from-backup backup-label' initialize_database_from_backup").twice

      # NotStarted
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check initialize_database_from_backup").and_return("NotStarted")
      expect { nx.initialize_database_from_backup }.to nap(5)

      # Failed
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check initialize_database_from_backup").and_return("Failed")
      expect { nx.initialize_database_from_backup }.to nap(5)
    end

    it "hops to refresh_certificates if initialize_database_from_backup command is succeeded" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check initialize_database_from_backup").and_return("Succeeded")
      expect { nx.initialize_database_from_backup }.to hop("refresh_certificates")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check initialize_database_from_backup").and_return("Unknown")
      expect { nx.initialize_database_from_backup }.to nap(5)
    end

    it "triggers initialize_database_from_backup with LATEST as backup_label for standbys" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check initialize_database_from_backup").and_return("NotStarted")
      expect(postgres_server).to receive(:standby?).and_return(true)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo postgres/bin/initialize-database-from-backup LATEST' initialize_database_from_backup")
      expect { nx.initialize_database_from_backup }.to nap(5)
    end
  end

  describe "#refresh_certificates" do
    it "waits for certificate creation by the parent resource" do
      expect(postgres_server.resource).to receive(:server_cert).and_return(nil)
      expect { nx.refresh_certificates }.to nap(5)
    end

    it "pushes certificates to vm and hops to configure during initial provisioning" do
      expect(sshable).to receive(:cmd).with("sudo -u postgres tee /dat/16/data/ca.crt > /dev/null", stdin: "root_cert_1\nroot_cert_2")
      expect(sshable).to receive(:cmd).with("sudo -u postgres tee /dat/16/data/server.crt > /dev/null", stdin: "server_cert")
      expect(sshable).to receive(:cmd).with("sudo -u postgres tee /dat/16/data/server.key > /dev/null", stdin: "server_cert_key")
      expect(sshable).to receive(:cmd).with("sudo -u postgres chmod 600 /dat/16/data/server.key")
      expect(nx).to receive(:refresh_walg_credentials)

      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect { nx.refresh_certificates }.to hop("configure")
    end

    it "hops to wait at times other than the initial provisioning" do
      expect(sshable).to receive(:cmd).with("sudo -u postgres tee /dat/16/data/ca.crt > /dev/null", stdin: "root_cert_1\nroot_cert_2")
      expect(sshable).to receive(:cmd).with("sudo -u postgres tee /dat/16/data/server.crt > /dev/null", stdin: "server_cert")
      expect(sshable).to receive(:cmd).with("sudo -u postgres tee /dat/16/data/server.key > /dev/null", stdin: "server_cert_key")
      expect(sshable).to receive(:cmd).with("sudo -u postgres chmod 600 /dat/16/data/server.key")
      expect(sshable).to receive(:cmd).with("sudo -u postgres pg_ctlcluster 16 main reload")
      expect(nx).to receive(:refresh_walg_credentials)
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

    it "hops to update_superuser_password if configure command is succeeded during the initial provisioning and if the server is primary" do
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --clean configure_postgres").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_postgres").and_return("Succeeded")
      expect(postgres_server).to receive(:primary?).and_return(true)
      expect { nx.configure }.to hop("update_superuser_password")
    end

    it "hops to wait_catch_up if configure command is succeeded during the initial provisioning and if the server is standby" do
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --clean configure_postgres").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_postgres").and_return("Succeeded")
      expect(postgres_server).to receive(:primary?).and_return(false)
      expect(postgres_server).to receive(:standby?).and_return(true)
      expect { nx.configure }.to hop("wait_catch_up")
    end

    it "hops to wait_recovery_completion if configure command is succeeded during the initial provisioning and if the server is doing pitr" do
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --clean configure_postgres").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_postgres").and_return("Succeeded")
      expect(postgres_server).to receive(:primary?).and_return(false)
      expect(postgres_server).to receive(:standby?).and_return(false)
      expect { nx.configure }.to hop("wait_recovery_completion")
    end

    it "hops to wait for primaries if configure command is succeeded at times other than the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --clean configure_postgres").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_postgres").and_return("Succeeded")
      expect(postgres_server).to receive(:standby?).and_return(false)
      expect { nx.configure }.to hop("wait")
    end

    it "hops to wait_catchup for standbys if configure command is succeeded at times other than the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --clean configure_postgres").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_postgres").and_return("Succeeded")
      expect(postgres_server).to receive(:standby?).and_return(true)
      expect(postgres_server).to receive(:synchronization_status).and_return("catching_up")
      expect { nx.configure }.to hop("wait_catch_up")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_postgres").and_return("Unknown")
      expect { nx.configure }.to nap(5)
    end
  end

  describe "#update_superuser_password" do
    it "updates password and pushes restart during the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(postgres_server).to receive(:run_query).with(/log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      expect(nx).to receive(:push).with(described_class, {}, "restart").and_call_original
      expect { nx.update_superuser_password }.to hop("restart")
    end

    it "updates password and hops to wait during initial provisioning if restart is already executed" do
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(postgres_server).to receive(:run_query).with(/log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      expect(nx.strand).to receive(:retval).and_return({"msg" => "postgres server is restarted"})
      expect { nx.update_superuser_password }.to hop("wait")
    end

    it "updates password and hops to wait at times other than the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?)
      expect(postgres_server).to receive(:run_query).with(/log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      expect { nx.update_superuser_password }.to hop("wait")
    end
  end

  describe "#wait_catch_up" do
    it "naps if the lag cannot be read or too high" do
      expect(postgres_server).to receive(:run_query).and_return("", "90000000")
      expect { nx.wait_catch_up }.to nap(30)
      expect { nx.wait_catch_up }.to nap(30)
    end

    it "sets the synchronization_status and hops to wait_synchronization for sync replication" do
      expect(postgres_server).to receive(:run_query).and_return("80000000")
      expect(postgres_server).to receive(:update).with(synchronization_status: "ready")
      expect(postgres_server).to receive(:incr_configure)
      expect(postgres_server.resource).to receive(:ha_type).and_return(PostgresResource::HaType::SYNC)
      expect { nx.wait_catch_up }.to hop("wait_synchronization")
    end

    it "sets the synchronization_status and hops to wait for async replication" do
      expect(postgres_server).to receive(:run_query).and_return("80000000")
      expect(postgres_server).to receive(:update).with(synchronization_status: "ready")
      expect(postgres_server).to receive(:incr_configure)
      expect(postgres_server.resource).to receive(:ha_type).and_return(PostgresResource::HaType::ASYNC)
      expect { nx.wait_catch_up }.to hop("wait")
    end
  end

  describe "#wait_synchronization" do
    it "hops to wait if sync replication is established" do
      expect(postgres_server).to receive(:run_query).and_return("quorum", "sync")
      expect { nx.wait_synchronization }.to hop("wait")
      expect { nx.wait_synchronization }.to hop("wait")
    end

    it "naps if sync replication is not established" do
      expect(postgres_server).to receive(:run_query).and_return("", "async")
      expect { nx.wait_synchronization }.to nap(30)
      expect { nx.wait_synchronization }.to nap(30)
    end
  end

  describe "#wait_recovery_completion" do
    it "naps if it is still in recovery and wal replay is not paused" do
      expect(postgres_server).to receive(:run_query).with("SELECT pg_is_in_recovery()").and_return("t")
      expect(postgres_server).to receive(:run_query).with("SELECT pg_get_wal_replay_pause_state()").and_return("not paused")
      expect { nx.wait_recovery_completion }.to nap(5)
    end

    it "stops wal replay and switches to new timeline if it is still in recovery but wal replay is paused" do
      expect(postgres_server).to receive(:run_query).with("SELECT pg_is_in_recovery()").and_return("t")
      expect(postgres_server).to receive(:run_query).with("SELECT pg_get_wal_replay_pause_state()").and_return("paused")
      expect(sshable).to receive(:cmd).with("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: "walg config")
      expect(sshable).to receive(:cmd).with("sudo tee /usr/lib/ssl/certs/blob_storage_ca.crt > /dev/null", stdin: "certs")

      expect(postgres_server).to receive(:run_query).with("SELECT pg_wal_replay_resume()")
      expect(Prog::Postgres::PostgresTimelineNexus).to receive(:assemble).and_return(instance_double(Strand, id: "375b1399-ec21-8eda-8859-2faee6ff6613"))
      expect(postgres_server).to receive(:timeline_id=).with("375b1399-ec21-8eda-8859-2faee6ff6613")
      expect(postgres_server).to receive(:timeline_access=).with("push")
      expect(postgres_server).to receive(:save_changes)
      expect { nx.wait_recovery_completion }.to hop("configure")
    end

    it "switches to new timeline if the recovery is completed" do
      expect(postgres_server).to receive(:run_query).with("SELECT pg_is_in_recovery()").and_return("f")
      expect(sshable).to receive(:cmd).with("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: "walg config")
      expect(sshable).to receive(:cmd).with("sudo tee /usr/lib/ssl/certs/blob_storage_ca.crt > /dev/null", stdin: "certs")

      expect(Prog::Postgres::PostgresTimelineNexus).to receive(:assemble).and_return(instance_double(Strand, id: "375b1399-ec21-8eda-8859-2faee6ff6613"))
      expect(postgres_server).to receive(:timeline_id=).with("375b1399-ec21-8eda-8859-2faee6ff6613")
      expect(postgres_server).to receive(:timeline_access=).with("push")
      expect(postgres_server).to receive(:save_changes)
      expect { nx.wait_recovery_completion }.to hop("configure")
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(30)
    end

    it "hops to wait_primary_destroy if take_over is set" do
      expect(nx).to receive(:when_take_over_set?).and_yield
      expect { nx.wait }.to hop("wait_primary_destroy")
    end

    it "hops to refresh_certificates if refresh_certificates is set" do
      expect(nx).to receive(:when_refresh_certificates_set?).and_yield
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "hops to update_superuser_password if update_superuser_password is set" do
      expect(nx).to receive(:when_update_superuser_password_set?).and_yield
      expect { nx.wait }.to hop("update_superuser_password")
    end

    it "hops to unavailable if checkup is set and the server is not available" do
      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")
    end

    it "naps if checkup is set but the server is available" do
      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(30)
    end

    it "hops to update_firewall_rules if update_firewall_rules is set" do
      expect(nx).to receive(:when_update_firewall_rules_set?).and_yield
      expect { nx.wait }.to hop("update_firewall_rules")
    end

    it "hops to configure if configure is set" do
      expect(nx).to receive(:when_configure_set?).and_yield
      expect { nx.wait }.to hop("configure")
    end
  end

  describe "#update_firewall_rules" do
    it "updates firewall rules and hops to wait" do
      expect(postgres_server).to receive(:ubid).and_return("dummy-ubid")
      fw = instance_double(Firewall, name: "dummy-ubid")
      expect(postgres_server.vm).to receive(:firewalls).and_return([fw])
      expect(fw).to receive(:destroy)
      expect(postgres_server).to receive(:create_resource_firewall_rules)
      expect(postgres_server.vm).to receive(:incr_update_firewall_rules)

      expect { nx.update_firewall_rules }.to hop("wait")
    end
  end

  describe "#unavailable" do
    it "hops to wait if the server is available" do
      expect(postgres_server).to receive(:primary?).and_return(true)
      expect(postgres_server).to receive(:failover_target).and_return(nil)
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.unavailable }.to hop("wait")
    end

    it "buds restart if the server is not available" do
      expect(postgres_server).to receive(:primary?).and_return(true)
      expect(postgres_server).to receive(:failover_target).and_return(nil)
      expect(nx).to receive(:available?).and_return(false)
      expect(nx).to receive(:bud).with(described_class, {}, :restart)
      expect { nx.unavailable }.to nap(5)
    end

    it "does not bud restart if there is already one restart going on" do
      expect(postgres_server).to receive(:primary?).and_return(true).twice
      expect(postgres_server).to receive(:failover_target).and_return(nil).twice
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.unavailable }.to nap(5)
      expect(nx).not_to receive(:bud).with(described_class, {}, :restart)
      expect { nx.unavailable }.to nap(5)
    end

    it "increments take_over if there is a failover target and increments destroy" do
      standby = instance_double(PostgresServer)
      expect(standby).to receive(:incr_take_over)
      expect(postgres_server).to receive(:primary?).and_return(true)
      expect(postgres_server).to receive(:failover_target).and_return(standby)
      expect(postgres_server).to receive(:incr_destroy)
      expect { nx.unavailable }.to nap(0)
    end
  end

  describe "#wait_primary_destroy" do
    it "naps if primary still exists" do
      expect(nx).to receive(:decr_take_over)
      expect(postgres_server.resource).to receive(:representative_server).and_return("something")
      expect { nx.wait_primary_destroy }.to nap(5)
    end

    it "hops to take_over if primary still exists" do
      expect(nx).to receive(:decr_take_over)
      expect(postgres_server.resource).to receive(:representative_server).and_return(nil)
      expect { nx.wait_primary_destroy }.to hop("take_over")
    end
  end

  describe "#take_over" do
    it "triggers promote if promote command is not sent yet or failed" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo pg_ctlcluster 16 main promote' promote_postgres").twice

      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check promote_postgres").and_return("NotStarted", "Failed")
      expect { nx.take_over }.to nap(0)
      expect { nx.take_over }.to nap(0)
    end

    it "updates the metadata and hops to configure if promote command is succeeded" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check promote_postgres").and_return("Succeeded")

      expect(postgres_server).to receive(:update).with(timeline_access: "push", representative_at: anything)
      expect(postgres_server.resource).to receive(:incr_refresh_dns_record)
      expect(postgres_server).to receive(:primary?).and_return(true)
      expect(postgres_server).to receive(:incr_configure)

      standby = instance_double(PostgresServer, primary?: false)
      expect(standby).to receive(:update).with(synchronization_status: "catching_up")
      expect(standby).to receive(:incr_configure)

      expect(postgres_server.resource).to receive(:servers).and_return([postgres_server, standby]).twice

      expect { nx.take_over }.to hop("configure")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check promote_postgres").and_return("Unknown")
      expect { nx.take_over }.to nap(5)
    end
  end

  describe "#destroy" do
    it "deletes resources and exits" do
      expect(postgres_server.vm).to receive(:private_subnets).and_return([])
      expect(postgres_server.vm).to receive(:incr_destroy)
      expect(postgres_server).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "postgres server is deleted"})
    end
  end

  describe "#restart" do
    it "restarts and exits" do
      expect(sshable).to receive(:cmd).with("sudo postgres/bin/restart")
      expect { nx.restart }.to exit({"msg" => "postgres server is restarted"})
    end
  end

  describe "#refresh_walg_credentials" do
    it "returns nil if blob storage is not configures" do
      expect(postgres_server.timeline).to receive(:blob_storage).and_return(nil)
      expect(nx.refresh_walg_credentials).to be_nil
    end
  end

  describe "#available?" do
    before do
      expect(sshable).to receive(:invalidate_cache_entry)
    end

    it "returns true if health check is successful" do
      expect(postgres_server).to receive(:run_query).with("SELECT 1").and_return("1")
      expect(nx.available?).to be(true)
    end

    it "returns true if the database is in crash recovery" do
      expect(postgres_server).to receive(:run_query).with("SELECT 1").and_raise(Sshable::SshError)
      expect(sshable).to receive(:cmd).with("sudo tail -n 5 /dat/16/data/pg_log/postgresql.log").and_return("redo in progress")
      expect(nx.available?).to be(true)
    end

    it "returns false otherwise" do
      expect(postgres_server).to receive(:run_query).with("SELECT 1").and_raise(Sshable::SshError)
      expect(sshable).to receive(:cmd).with("sudo tail -n 5 /dat/16/data/pg_log/postgresql.log").and_return("not doing redo")
      expect(nx.available?).to be(false)
    end
  end
end
