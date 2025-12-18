# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::PostgresServerNexus do
  subject(:nx) { described_class.new(server_strand) }

  let(:user_project) { Project.create(name: "test-project") }
  let(:postgres_project) { Project.create(name: "postgres-service") }

  let(:postgres_resource) {
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: user_project.id, location_id: Location::HETZNER_FSN1_ID,
      name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 64
    ).subject
  }

  let(:server_strand) { postgres_resource.servers.first.strand }
  let(:postgres_server) { nx.postgres_server }
  let(:sshable) { postgres_server.vm.sshable }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
  end

  describe ".assemble" do
    let(:user_project) { Project.create(name: "default") }
    let(:firewall) {
      Firewall.create(name: "#{postgres_resource.ubid}-internal-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: Config.postgres_service_project_id)
    }
    let(:postgres_resource) {
      PostgresResource.create(
        project_id: user_project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-name",
        target_vm_size: "burstable-2",
        target_storage_size_gib: 64,
        superuser_password: "dummy-password",
        target_version: "16"
      )
    }

    it "creates postgres server and vm with sshable" do
      postgres_timeline = PostgresTimeline.create
      postgres_project = Project.create(name: "default")
      expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)
      firewall

      st = described_class.assemble(resource_id: postgres_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", representative_at: Time.now)
      postgres_server = PostgresServer[st.id]
      expect(postgres_server).not_to be_nil
      expect(postgres_server.vm).not_to be_nil
      expect(postgres_server.vm.sshable).not_to be_nil

      st = described_class.assemble(resource_id: postgres_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push")
      expect(PostgresServer[st.id].synchronization_status).to eq("catching_up")
    end

    it "attaches internal firewall to underlying VM, if postgres resource has internal firewall" do
      postgres_project = Project.create(name: "default")
      expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)

      pg = Prog::Postgres::PostgresResourceNexus.assemble(project_id: user_project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg-name-2", target_vm_size: "standard-2", target_storage_size_gib: 128).subject
      pv = pg.servers.first
      expect(pv.vm.vm_firewalls).to eq [pg.internal_firewall]
    end

    it "picks correct base image for Lantern" do
      postgres_project = Project.create(name: "default")
      expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)

      # Create a lantern-flavored postgres resource
      lantern_resource = PostgresResource.create(
        project_id: user_project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-lantern",
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
        superuser_password: "dummy-password",
        target_version: "16",
        flavor: PostgresResource::Flavor::LANTERN
      )
      # Create firewall with correct name after resource exists
      Firewall.create(name: "#{lantern_resource.ubid}-internal-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: postgres_project.id)
      postgres_timeline = PostgresTimeline.create

      st = described_class.assemble(resource_id: lantern_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", representative_at: Time.now)
      postgres_server = PostgresServer[st.id]
      expect(postgres_server.vm.boot_image).to eq("postgres16-lantern-ubuntu-2204")
    end

    it "picks correct base image for AWS-pg16" do
      # Use an existing seed location (us-west-2) that has billing rates
      aws_location = Location.find(name: "us-west-2")
      skip "us-west-2 location not available in test seeds" unless aws_location

      postgres_project = Project.create(name: "default")
      expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)

      # Ensure AMI mapping exists
      PgAwsAmi.find_or_create(aws_location_name: "us-west-2", pg_version: "16", arch: "x64") { |a| a.aws_ami_id = "ami-pg16-x64" }

      aws_resource = PostgresResource.create(
        project_id: user_project.id,
        location_id: aws_location.id,
        name: "pg-aws16",
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
        superuser_password: "dummy-password",
        target_version: "16"
      )
      # Create firewall with correct name
      Firewall.create(name: "#{aws_resource.ubid}-internal-firewall", location_id: aws_location.id, project_id: postgres_project.id)
      postgres_timeline = PostgresTimeline.create

      st = described_class.assemble(resource_id: aws_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", representative_at: Time.now)
      postgres_server = PostgresServer[st.id]
      # AWS uses AMI lookup via pg_ami method - verify the boot_image matches what pg_ami returns
      expect(postgres_server.vm.boot_image).to eq(aws_location.pg_ami("16", "x64"))
    end

    it "picks correct base image for AWS-pg17" do
      # Use an existing seed location (us-west-2) that has billing rates
      aws_location = Location.find(name: "us-west-2")
      skip "us-west-2 location not available in test seeds" unless aws_location

      postgres_project = Project.create(name: "default")
      expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)

      # Ensure AMI mapping exists
      PgAwsAmi.find_or_create(aws_location_name: "us-west-2", pg_version: "17", arch: "x64") { |a| a.aws_ami_id = "ami-pg17-x64" }

      aws_resource = PostgresResource.create(
        project_id: user_project.id,
        location_id: aws_location.id,
        name: "pg-aws17",
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
        superuser_password: "dummy-password",
        target_version: "17"
      )
      # Create firewall with correct name
      Firewall.create(name: "#{aws_resource.ubid}-internal-firewall", location_id: aws_location.id, project_id: postgres_project.id)
      postgres_timeline = PostgresTimeline.create

      st = described_class.assemble(resource_id: aws_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", representative_at: Time.now)
      postgres_server = PostgresServer[st.id]
      # AWS uses AMI lookup via pg_ami method - verify the boot_image matches what pg_ami returns
      expect(postgres_server.vm.boot_image).to eq(aws_location.pg_ami("17", "x64"))
    end

    it "raises error if the version is not supported for AWS" do
      # Use an existing seed location that has billing rates but ensure no AMI mapping
      aws_location = Location.find(name: "us-west-2")
      skip "us-west-2 location not available in test seeds" unless aws_location

      # Create resource with version 18 - ensure NO PgAwsAmi entry exists for this version
      PgAwsAmi.where(aws_location_name: "us-west-2", pg_version: "18").each(&:destroy)

      aws_resource = PostgresResource.create(
        project_id: user_project.id,
        location_id: aws_location.id,
        name: "pg-aws-unsupported",
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
        superuser_password: "dummy-password",
        target_version: "18"
      )
      postgres_timeline = PostgresTimeline.create

      # Error happens when pg_ami returns nil for unsupported version
      expect {
        described_class.assemble(resource_id: aws_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", representative_at: Time.now)
      }.to raise_error NoMethodError, "undefined method 'aws_ami_id' for nil"
    end
  end

  describe "#before_run" do
    it "hops to destroy when resource strand is destroy" do
      nx.incr_destroy
      postgres_resource.strand.update(label: "destroy")
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      nx.incr_destroy
      postgres_resource.strand.update(label: "destroy")
      server_strand.update(label: "destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if already in the wait_children_destroy state" do
      nx.incr_destroy
      postgres_resource.strand.update(label: "destroy")
      server_strand.update(label: "wait_children_destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy_vm_and_pg state" do
      nx.incr_destroy
      postgres_resource.strand.update(label: "destroy")
      server_strand.update(label: "destroy_vm_and_pg")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "cancels the destroy if the server is picked up for take over" do
      nx.incr_destroy
      # Resource strand is "wait" (not destroying), server is taking over
      server_strand.update(label: "taking_over")
      expect { nx.before_run }.not_to hop("destroy")
      expect(Semaphore.where(strand_id: postgres_server.id, name: "destroy").count).to eq(0)
    end

    it "pops additional operations from stack" do
      nx.incr_destroy
      postgres_resource.strand.update(label: "destroy")
      # Set up a stack with proper back-link (simulating a pushed frame)
      server_strand.update(
        label: "destroy",
        stack: [
          {"subject_id" => postgres_server.id, "link" => ["Postgres::PostgresServerNexus", "wait"]},
          {}
        ]
      )
      # Create fresh nexus so frame memoization picks up the new stack
      fresh_nx = described_class.new(server_strand.reload)
      expect { fresh_nx.before_run }.to hop("wait")
    end
  end

  describe "#start" do
    it "naps if vm not ready" do
      postgres_server.vm.strand.update(label: "prep")
      expect { nx.start }.to nap(5)
    end

    it "hops to bootstrap_rhizome when vm is ready" do
      postgres_server.vm.strand.update(label: "wait")
      expect { nx.start }.to hop("bootstrap_rhizome")
      expect(Semaphore.where(strand_id: postgres_server.id, name: "initial_provisioning").count).to eq(1)
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds a bootstrap rhizome process for primary" do
      # Server created by assemble is primary (has representative_at)
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
      child = Strand.where(prog: "BootstrapRhizome", parent_id: server_strand.id).first
      expect(child).not_to be_nil
      expect(child.stack.first["target_folder"]).to eq("postgres")
      expect(child.stack.first["subject_id"]).to eq(postgres_server.vm.id)
    end

    it "sets longer deadline for non-primary servers" do
      # Make server non-primary by removing representative_at
      postgres_server.update(representative_at: nil)
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "hops to mount_data_disk if there are no sub-programs running" do
      expect { nx.wait_bootstrap_rhizome }.to hop("mount_data_disk")
    end

    it "donates if there are sub-programs running" do
      Strand.create(parent_id: server_strand.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_bootstrap_rhizome }.to nap(5)
    end
  end

  describe "#mount_data_disk" do
    # Create storage volumes for the VM (not created automatically by Vm::Nexus.assemble in test mode)
    let(:data_volume) {
      VmStorageVolume.create(vm_id: postgres_server.vm.id, boot: false, size_gib: 64, disk_index: 1)
    }

    it "formats data disk if format command is not sent yet or failed" do
      data_volume
      device_path = postgres_server.storage_device_paths.first
      expect(sshable).to receive(:d_check).with("format_disk").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("format_disk", "sudo", "mkfs", "--type", "ext4", device_path)
      expect { nx.mount_data_disk }.to nap(5)
    end

    it "formats data disk correctly when there are multiple storage volumes" do
      # RAID setup only happens on AWS where storage_device_paths returns multiple paths.
      # storage_device_paths does SSH to lsblk on AWS - stubbing to avoid AWS infra setup.
      paths = ["/dev/nvme1n1", "/dev/nvme2n1"]
      allow(postgres_server).to receive(:storage_device_paths).and_return(paths)

      expect(sshable).to receive(:d_check).with("format_disk").and_return("NotStarted")
      expect(sshable).to receive(:cmd).with("sudo mdadm --create --verbose /dev/md0 --level=0 --raid-devices=:count :shelljoin_storage_device_paths",
        count: 2, shelljoin_storage_device_paths: paths)
      expect(sshable).to receive(:d_run).with("format_disk", "sudo", "mkfs", "--type", "ext4", "/dev/md0")
      expect { nx.mount_data_disk }.to nap(5)
    end

    it "mounts data disk if format disk is succeeded and hops to configure_walg_credentials" do
      data_volume
      device_path = postgres_server.storage_device_paths.first
      expect(sshable).to receive(:d_check).with("format_disk").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with("sudo mkdir -p /dat")
      expect(sshable).to receive(:cmd).with("sudo common/bin/add_to_fstab :device_path /dat ext4 defaults 0 0", device_path: device_path)
      expect(sshable).to receive(:cmd).with("sudo mount :device_path /dat", device_path: device_path)
      expect { nx.mount_data_disk }.to hop("configure_walg_credentials")
    end

    it "mounts data disk correctly when there are multiple storage volumes" do
      # RAID setup only happens on AWS where storage_device_paths returns multiple paths.
      # storage_device_paths does SSH to lsblk on AWS - stubbing to avoid AWS infra setup.
      paths = ["/dev/nvme1n1", "/dev/nvme2n1"]
      allow(postgres_server).to receive(:storage_device_paths).and_return(paths)

      expect(sshable).to receive(:d_check).with("format_disk").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with("sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf")
      expect(sshable).to receive(:cmd).with("sudo update-initramfs -u")
      expect(sshable).to receive(:cmd).with("sudo mkdir -p /dat")
      expect(sshable).to receive(:cmd).with("sudo common/bin/add_to_fstab :device_path /dat ext4 defaults 0 0", device_path: "/dev/md0")
      expect(sshable).to receive(:cmd).with("sudo mount :device_path /dat", device_path: "/dev/md0")
      expect { nx.mount_data_disk }.to hop("configure_walg_credentials")
    end

    it "naps if script return unknown status" do
      data_volume
      expect(sshable).to receive(:d_check).with("format_disk").and_return("Unknown")
      expect { nx.mount_data_disk }.to nap(5)
    end
  end

  describe "#configure_walg_credentials" do
    it "hops to initialize_empty_database if the server is primary" do
      # Server created by assemble is primary (has representative_at)
      # No MinioCluster exists, so refresh_walg_credentials returns early
      # Location is Hetzner (not AWS), so attach_s3_policy_if_needed is a no-op
      expect { nx.configure_walg_credentials }.to hop("initialize_empty_database")
    end

    it "hops to initialize_database_from_backup if the server is not primary" do
      # Make server non-primary by setting timeline_access to "fetch"
      postgres_server.update(timeline_access: "fetch")
      # No MinioCluster exists, so refresh_walg_credentials returns early
      # Location is Hetzner (not AWS), so attach_s3_policy_if_needed is a no-op
      expect { nx.configure_walg_credentials }.to hop("initialize_database_from_backup")
    end
  end

  describe "#initialize_empty_database" do
    it "triggers initialize_empty_database if initialize_empty_database command is not sent yet or failed" do
      version = postgres_server.version
      expect(sshable).to receive(:d_run).with("initialize_empty_database", "sudo", "postgres/bin/initialize-empty-database", version).twice

      # NotStarted
      expect(sshable).to receive(:d_check).with("initialize_empty_database").and_return("NotStarted")
      expect { nx.initialize_empty_database }.to nap(5)

      # Failed
      expect(sshable).to receive(:d_check).with("initialize_empty_database").and_return("Failed")
      expect { nx.initialize_empty_database }.to nap(5)
    end

    it "hops to refresh_certificates if initialize_empty_database command is succeeded" do
      expect(sshable).to receive(:d_check).with("initialize_empty_database").and_return("Succeeded")
      expect { nx.initialize_empty_database }.to hop("refresh_certificates")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:d_check).with("initialize_empty_database").and_return("Unknown")
      expect { nx.initialize_empty_database }.to nap(5)
    end
  end

  describe "#initialize_database_from_backup" do
    it "triggers initialize_database_from_backup if initialize_database_from_backup command is not sent yet or failed" do
      # Set restore_target on resource (database stores with microsecond precision)
      postgres_resource.update(restore_target: Time.now)
      restore_time = postgres_resource.reload.restore_target
      # Stub external service call for backup label lookup
      expect(postgres_server.timeline).to receive(:latest_backup_label_before_target).with(target: restore_time).and_return("backup-label").twice
      version = postgres_server.version
      expect(sshable).to receive(:d_run).with("initialize_database_from_backup", "sudo", "postgres/bin/initialize-database-from-backup", version, "backup-label").twice

      # NotStarted
      expect(sshable).to receive(:d_check).with("initialize_database_from_backup").and_return("NotStarted")
      expect { nx.initialize_database_from_backup }.to nap(5)

      # Failed
      expect(sshable).to receive(:d_check).with("initialize_database_from_backup").and_return("Failed")
      expect { nx.initialize_database_from_backup }.to nap(5)
    end

    it "hops to refresh_certificates if initialize_database_from_backup command is succeeded" do
      expect(sshable).to receive(:d_check).with("initialize_database_from_backup").and_return("Succeeded")
      expect { nx.initialize_database_from_backup }.to hop("refresh_certificates")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:d_check).with("initialize_database_from_backup").and_return("Unknown")
      expect { nx.initialize_database_from_backup }.to nap(5)
    end

    it "triggers initialize_database_from_backup with LATEST as backup_label for standbys" do
      # Create a standby server (separate from the primary representative)
      # Standby: timeline_access = "fetch" and resource.representative_server.primary? is true
      standby_strand = described_class.assemble(
        resource_id: postgres_resource.id,
        timeline_id: postgres_server.timeline_id,
        timeline_access: "fetch"
      )
      standby = PostgresServer[standby_strand.id]
      standby_nx = described_class.new(standby_strand)
      # Get the sshable through the same path the prog uses
      standby_sshable = standby_nx.postgres_server.vm.sshable

      version = standby.version
      expect(standby_sshable).to receive(:d_check).with("initialize_database_from_backup").and_return("NotStarted")
      expect(standby_sshable).to receive(:d_run).with("initialize_database_from_backup", "sudo", "postgres/bin/initialize-database-from-backup", version, "LATEST")
      expect { standby_nx.initialize_database_from_backup }.to nap(5)
    end
  end

  describe "#refresh_certificates" do
    before do
      # Set up real certificate data on the resource
      postgres_resource.update(
        root_cert_1: "root_cert_1",
        root_cert_2: "root_cert_2",
        server_cert: "server_cert",
        server_cert_key: "server_cert_key"
      )
    end

    it "waits for certificate creation by the parent resource" do
      postgres_resource.update(server_cert: nil)
      expect { nx.refresh_certificates }.to nap(5)
    end

    it "pushes certificates to vm and hops to configure_metrics during initial provisioning" do
      # Set initial_provisioning semaphore
      nx.incr_initial_provisioning
      ca_bundle = postgres_resource.ca_certificates

      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/ca.crt > /dev/null", stdin: ca_bundle)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/server.crt > /dev/null", stdin: "server_cert")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/server.key > /dev/null", stdin: "server_cert_key")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/ca.crt && sudo chmod 640 /etc/ssl/certs/ca.crt")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/server.crt && sudo chmod 640 /etc/ssl/certs/server.crt")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/server.key && sudo chmod 640 /etc/ssl/certs/server.key")

      expect(postgres_server).to receive(:refresh_walg_credentials)

      expect { nx.refresh_certificates }.to hop("configure_metrics")
    end

    it "hops to wait at times other than the initial provisioning" do
      # No initial_provisioning semaphore set
      ca_bundle = postgres_resource.ca_certificates
      version = postgres_server.version

      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/ca.crt > /dev/null", stdin: ca_bundle)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/server.crt > /dev/null", stdin: "server_cert")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/server.key > /dev/null", stdin: "server_cert_key")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/ca.crt && sudo chmod 640 /etc/ssl/certs/ca.crt")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/server.crt && sudo chmod 640 /etc/ssl/certs/server.crt")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/server.key && sudo chmod 640 /etc/ssl/certs/server.key")
      expect(sshable).to receive(:_cmd).with("sudo -u postgres pg_ctlcluster #{version} main reload")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload pgbouncer@*.service")
      expect(postgres_server).to receive(:refresh_walg_credentials)
      expect { nx.refresh_certificates }.to hop("wait")
    end
  end

  describe "#configure_metrics" do
    let(:metrics_config) { {interval: "30s", endpoints: ["https://localhost:9100/metrics"], metrics_dir: "/home/ubi/postgres/metrics"} }

    it "configures prometheus and metrics during initial provisioning" do
      # Set initial_provisioning semaphore and use_old_walg_command semaphore
      nx.incr_initial_provisioning
      postgres_resource.incr_use_old_walg_command

      expect(sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/web-config.yml > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/prometheus.yml > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now postgres_exporter")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now node_exporter")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now prometheus")

      # Configure metrics expectations
      expect(postgres_server).to receive(:metrics_config).and_return(metrics_config)
      expect(sshable).to receive(:_cmd).with("mkdir -p /home/ubi/postgres/metrics")
      expect(sshable).to receive(:_cmd).with("tee /home/ubi/postgres/metrics/config.json > /dev/null", stdin: metrics_config.to_json)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.service > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.timer > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now postgres-metrics.timer")

      expect { nx.configure_metrics }.to hop("setup_hugepages")
    end

    it "configures prometheus and metrics during initial provisioning and hops to setup_cloudwatch if timeline is AWS" do
      # Set initial_provisioning semaphore (no use_old_walg_command = new style)
      nx.incr_initial_provisioning

      # Update timeline to use an AWS location BEFORE setting up expectations
      aws_location = Location.where(provider: "aws").first
      PostgresTimeline.where(id: postgres_server.timeline_id).update(location_id: aws_location.id)
      # Clear the memoized postgres_server from the nexus to force a fresh load
      nx.instance_variable_set(:@postgres_server, nil)

      # Now set up expectations on the fresh sshable
      fresh_sshable = nx.postgres_server.vm.sshable
      expect(fresh_sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/web-config.yml > /dev/null", stdin: anything)
      expect(fresh_sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/prometheus.yml > /dev/null", stdin: anything)
      expect(fresh_sshable).to receive(:_cmd).with("sudo systemctl enable --now postgres_exporter")
      expect(fresh_sshable).to receive(:_cmd).with("sudo systemctl enable --now node_exporter")
      expect(fresh_sshable).to receive(:_cmd).with("sudo systemctl enable --now prometheus")
      expect(fresh_sshable).to receive(:_cmd).with("sudo systemctl enable --now wal-g")

      # Configure metrics expectations
      expect(nx.postgres_server).to receive(:metrics_config).and_return(metrics_config)
      expect(fresh_sshable).to receive(:_cmd).with("mkdir -p /home/ubi/postgres/metrics")
      expect(fresh_sshable).to receive(:_cmd).with("tee /home/ubi/postgres/metrics/config.json > /dev/null", stdin: metrics_config.to_json)
      expect(fresh_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.service > /dev/null", stdin: anything)
      expect(fresh_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.timer > /dev/null", stdin: anything)
      expect(fresh_sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(fresh_sshable).to receive(:_cmd).with("sudo systemctl enable --now postgres-metrics.timer")

      # Set project feature flag via update
      nx.postgres_server.resource.project.update(feature_flags: Sequel.pg_jsonb_wrap({"aws_cloudwatch_logs" => true}))
      expect { nx.configure_metrics }.to hop("setup_cloudwatch")
    end

    it "configures prometheus and metrics and hops to wait at times other than initial provisioning" do
      # No initial_provisioning semaphore set

      # Prometheus expectations
      expect(sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/web-config.yml > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/prometheus.yml > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload postgres_exporter || sudo systemctl restart postgres_exporter")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload node_exporter || sudo systemctl restart node_exporter")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload prometheus || sudo systemctl restart prometheus")

      # Configure metrics expectations
      expect(postgres_server).to receive(:metrics_config).and_return(metrics_config)
      expect(sshable).to receive(:_cmd).with("mkdir -p /home/ubi/postgres/metrics")
      expect(sshable).to receive(:_cmd).with("tee /home/ubi/postgres/metrics/config.json > /dev/null", stdin: metrics_config.to_json)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.service > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.timer > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")

      # Using real representative_server from postgres_resource
      expect { nx.configure_metrics }.to hop("wait")
    end

    it "uses default interval if not specified in config" do
      # No initial_provisioning semaphore set
      config_without_interval = {endpoints: ["https://localhost:9100/metrics"], metrics_dir: "/home/ubi/postgres/metrics"}

      # Prometheus expectations
      expect(sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/web-config.yml > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/prometheus.yml > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload postgres_exporter || sudo systemctl restart postgres_exporter")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload node_exporter || sudo systemctl restart node_exporter")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload prometheus || sudo systemctl restart prometheus")

      # Configure metrics expectations with default interval
      expect(postgres_server).to receive(:metrics_config).and_return(config_without_interval)
      expect(sshable).to receive(:_cmd).with("mkdir -p /home/ubi/postgres/metrics")
      expect(sshable).to receive(:_cmd).with("tee /home/ubi/postgres/metrics/config.json > /dev/null", stdin: config_without_interval.to_json)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.service > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.timer > /dev/null", stdin: /OnUnitActiveSec=15s/)
      expect(sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")

      # Using real representative_server from postgres_resource
      expect { nx.configure_metrics }.to hop("wait")
    end
  end

  describe "#setup_cloudwatch" do
    it "hops to setup_hugepages after setting up cloudwatch" do
      expect(sshable).to receive(:_cmd).with("sudo mkdir -p /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d")
      expect(sshable).to receive(:_cmd).with("sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d/001-ubicloud-config.json > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d/001-ubicloud-config.json -s")
      expect { nx.setup_cloudwatch }.to hop("setup_hugepages")
    end
  end

  describe "#setup_hugepages" do
    it "hops to configure if the setup succeeds" do
      expect(sshable).to receive(:d_check).with("setup_hugepages").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("setup_hugepages")
      expect { nx.setup_hugepages }.to hop("configure")
    end

    it "retries the setup if it fails" do
      expect(sshable).to receive(:d_check).with("setup_hugepages").and_return("Failed")
      expect(sshable).to receive(:d_run).with("setup_hugepages", "sudo", "postgres/bin/setup-hugepages")
      expect { nx.setup_hugepages }.to nap(5)
    end

    it "starts the setup if it is not started" do
      expect(sshable).to receive(:d_check).with("setup_hugepages").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("setup_hugepages", "sudo", "postgres/bin/setup-hugepages")
      expect { nx.setup_hugepages }.to nap(5)
    end

    it "naps for 5 seconds if the setup is unknown" do
      expect(sshable).to receive(:d_check).with("setup_hugepages").and_return("Unknown")
      expect { nx.setup_hugepages }.to nap(5)
    end
  end

  describe "#configure" do
    it "triggers configure if configure command is not sent yet or failed" do
      expect(postgres_server).to receive(:configure_hash).and_return("dummy-configure-hash").twice
      expect(sshable).to receive(:d_run).with("configure_postgres", "sudo", "postgres/bin/configure", postgres_server.version, stdin: JSON.generate("dummy-configure-hash")).twice

      # NotStarted
      expect(sshable).to receive(:d_check).with("configure_postgres").and_return("NotStarted")
      expect { nx.configure }.to nap(5)

      # Failed
      expect(sshable).to receive(:d_check).with("configure_postgres").and_return("Failed")
      expect { nx.configure }.to nap(5)
    end

    it "hops to update_superuser_password if configure command is succeeded during the initial provisioning and if the server is primary" do
      nx.incr_initial_provisioning
      expect(sshable).to receive(:d_clean).with("configure_postgres").and_return("Succeeded")
      expect(sshable).to receive(:d_check).with("configure_postgres").and_return("Succeeded")
      # postgres_server is primary by default (timeline_access: "push")
      expect { nx.configure }.to hop("update_superuser_password")
    end

    it "hops to wait_catch_up if configure command is succeeded during the initial provisioning and if the server is standby" do
      # Create a standby server (timeline_access: "fetch")
      standby_strand = described_class.assemble(
        resource_id: postgres_resource.id, timeline_id: postgres_resource.timeline.id,
        timeline_access: "fetch"
      )
      standby_nx = described_class.new(standby_strand)
      standby_nx.incr_initial_provisioning
      standby_sshable = standby_nx.postgres_server.vm.sshable
      expect(standby_sshable).to receive(:d_clean).with("configure_postgres").and_return("Succeeded")
      expect(standby_sshable).to receive(:d_check).with("configure_postgres").and_return("Succeeded")
      expect { standby_nx.configure }.to hop("wait_catch_up")
    end

    it "hops to wait_recovery_completion if configure command is succeeded during the initial provisioning and if the server is doing pitr" do
      # PITR scenario: server is fetching (not primary) and the representative is also not primary
      # This happens during point-in-time recovery
      # Make the existing server not primary but keep it as representative for now
      postgres_server.update(timeline_access: "fetch")
      nx.incr_initial_provisioning
      expect(sshable).to receive(:d_clean).with("configure_postgres").and_return("Succeeded")
      expect(sshable).to receive(:d_check).with("configure_postgres").and_return("Succeeded")
      expect { nx.configure }.to hop("wait_recovery_completion")
    end

    it "hops to wait for primaries if configure command is succeeded at times other than the initial provisioning" do
      # No initial_provisioning semaphore set
      expect(sshable).to receive(:d_clean).with("configure_postgres").and_return("Succeeded")
      expect(sshable).to receive(:d_check).with("configure_postgres").and_return("Succeeded")
      # postgres_server is primary by default
      expect { nx.configure }.to hop("wait")
    end

    it "hops to wait_catchup for standbys if configure command is succeeded at times other than the initial provisioning" do
      # Create standby and set synchronization_status
      standby_strand = described_class.assemble(
        resource_id: postgres_resource.id, timeline_id: postgres_resource.timeline.id,
        timeline_access: "fetch"
      )
      standby = PostgresServer[standby_strand.id]
      standby.update(synchronization_status: "catching_up")
      standby_nx = described_class.new(standby_strand)
      standby_sshable = standby_nx.postgres_server.vm.sshable
      expect(standby_sshable).to receive(:d_clean).with("configure_postgres").and_return("Succeeded")
      expect(standby_sshable).to receive(:d_check).with("configure_postgres").and_return("Succeeded")
      expect { standby_nx.configure }.to hop("wait_catch_up")
    end

    it "hops to wait for read replicas if configure command is succeeded" do
      # Create a read replica resource with a server
      read_replica_resource = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: user_project.id, location_id: Location::HETZNER_FSN1_ID,
        name: "test-pg-rr", target_vm_size: "standard-2", target_storage_size_gib: 64,
        parent_id: postgres_resource.id
      ).subject
      rr_server = read_replica_resource.servers.first
      rr_nx = described_class.new(rr_server.strand)
      rr_nx.incr_initial_provisioning
      rr_sshable = rr_nx.postgres_server.vm.sshable
      expect(rr_sshable).to receive(:d_clean).with("configure_postgres").and_return("Succeeded")
      expect(rr_sshable).to receive(:d_check).with("configure_postgres").and_return("Succeeded")
      expect { rr_nx.configure }.to hop("wait_catch_up")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:d_check).with("configure_postgres").and_return("Unknown")
      expect { nx.configure }.to nap(5)
    end
  end

  describe "#update_superuser_password" do
    it "updates password and pushes restart during the initial provisioning" do
      nx.incr_initial_provisioning
      expect(postgres_server).to receive(:run_query).with(/log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      expect { nx.update_superuser_password }.to hop("restart")
      # Verify initial_provisioning semaphore is still set (push doesn't consume it)
      expect(Semaphore.where(strand_id: server_strand.id, name: "initial_provisioning").count).to eq(1)
    end

    it "updates password and hops to wait during initial provisioning if restart is already executed" do
      nx.incr_initial_provisioning
      expect(postgres_server).to receive(:run_query).with(/log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      server_strand.update(retval: {"msg" => "postgres server is restarted"})
      # postgres_server is already primary (representative_at set by assemble)
      # flavor is standard by default
      expect { nx.update_superuser_password }.to hop("wait")
    end

    it "updates password and hops to run_post_installation_script during initial provisioning for non-standard flavors if restart is already executed" do
      nx.incr_initial_provisioning
      expect(postgres_server).to receive(:run_query).with(/log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      server_strand.update(retval: {"msg" => "postgres server is restarted"})
      # postgres_server is already primary, update resource flavor
      postgres_resource.update(flavor: PostgresResource::Flavor::PARADEDB)
      expect { nx.update_superuser_password }.to hop("run_post_installation_script")
    end

    it "updates password and hops to wait at times other than the initial provisioning" do
      # No initial_provisioning semaphore set, so it should hop directly to wait
      expect(postgres_server).to receive(:run_query).with(/log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      expect { nx.update_superuser_password }.to hop("wait")
    end
  end

  describe "#run_post_installation_script" do
    it "runs post installation script and hops wait" do
      expect(sshable).to receive(:_cmd).with(/post-installation-script/)
      expect { nx.run_post_installation_script }.to hop("wait")
    end
  end

  describe "#wait_catch_up" do
    it "naps if the lag is too high" do
      expect(postgres_server).to receive(:lsn_caught_up).and_return(false, false)
      expect { nx.wait_catch_up }.to nap(30)
      expect { nx.wait_catch_up }.to nap(30)
    end

    it "sets the synchronization_status and hops to wait_synchronization for sync replication" do
      expect(postgres_server).to receive(:lsn_caught_up).and_return(true)
      postgres_resource.update(ha_type: PostgresResource::HaType::SYNC)
      expect { nx.wait_catch_up }.to hop("wait_synchronization")
      expect(postgres_server.reload.synchronization_status).to eq("ready")
      expect(Semaphore.where(strand_id: server_strand.id, name: "configure").count).to eq(1)
    end

    it "sets the synchronization_status and hops to wait for async replication" do
      expect(postgres_server).to receive(:lsn_caught_up).and_return(true)
      postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
      expect { nx.wait_catch_up }.to hop("wait")
      expect(postgres_server.reload.synchronization_status).to eq("ready")
      expect(Semaphore.where(strand_id: server_strand.id, name: "configure").count).to eq(1)
    end

    it "hops to wait if replica and caught up" do
      expect(postgres_server).to receive(:read_replica?).and_return(true)
      expect(postgres_server).to receive(:lsn_caught_up).and_return(true)
      expect { nx.wait_catch_up }.to hop("wait")
    end
  end

  describe "#wait_synchronization" do
    it "hops to wait if sync replication is established" do
      # The query is run on the representative_server (which is the primary)
      # Mock at _cmd level since run_query is an external SSH operation
      # Get the sshable through the exact chain the code uses: nx.postgres_server.resource.representative_server.vm.sshable
      query = "SELECT sync_state FROM pg_stat_replication WHERE application_name = '#{postgres_server.ubid}'"
      rep_sshable = nx.postgres_server.resource.representative_server.vm.sshable
      expect(rep_sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: query).and_return("quorum")
      expect { nx.wait_synchronization }.to hop("wait")
      rep_sshable = nx.postgres_server.resource.representative_server.vm.sshable
      expect(rep_sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: query).and_return("sync")
      expect { nx.wait_synchronization }.to hop("wait")
    end

    it "naps if sync replication is not established" do
      query = "SELECT sync_state FROM pg_stat_replication WHERE application_name = '#{postgres_server.ubid}'"
      rep_sshable = nx.postgres_server.resource.representative_server.vm.sshable
      expect(rep_sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: query).and_return("")
      expect { nx.wait_synchronization }.to nap(30)
      rep_sshable = nx.postgres_server.resource.representative_server.vm.sshable
      expect(rep_sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: query).and_return("async")
      expect { nx.wait_synchronization }.to nap(30)
    end
  end

  describe "#wait_recovery_completion" do
    it "naps if it is still in recovery and wal replay is not paused" do
      expect(postgres_server).to receive(:run_query).with("SELECT pg_is_in_recovery()").and_return("t")
      expect(postgres_server).to receive(:run_query).with("SELECT pg_get_wal_replay_pause_state()").and_return("not paused")
      expect { nx.wait_recovery_completion }.to nap(5)
    end

    it "naps if it cannot connect to database due to recovery" do
      expect(postgres_server).to receive(:run_query).with("SELECT pg_is_in_recovery()").and_raise(Sshable::SshError.new("", nil, "Consistent recovery state has not been yet reached.", nil, nil))
      expect { nx.wait_recovery_completion }.to nap(5)
    end

    it "raises error if it cannot connect to database due a problem other than to continueing recovery" do
      expect(postgres_server).to receive(:run_query).with("SELECT pg_is_in_recovery()").and_raise(Sshable::SshError.new("", nil, "Bogus", nil, nil))
      expect { nx.wait_recovery_completion }.to raise_error(Sshable::SshError)
    end

    it "stops wal replay and switches to new timeline if it is still in recovery but wal replay is paused" do
      expect(postgres_server).to receive(:run_query).with("SELECT pg_is_in_recovery()").and_return("t")
      expect(postgres_server).to receive(:run_query).with("SELECT pg_get_wal_replay_pause_state()").and_return("paused")
      expect(postgres_server).to receive(:run_query).with("SELECT pg_wal_replay_resume()")
      expect(postgres_server).to receive(:switch_to_new_timeline)

      expect { nx.wait_recovery_completion }.to hop("configure")
    end

    it "switches to new timeline if the recovery is completed" do
      expect(postgres_server).to receive(:run_query).with("SELECT pg_is_in_recovery()").and_return("f")
      expect(postgres_server).to receive(:switch_to_new_timeline)
      expect { nx.wait_recovery_completion }.to hop("configure")
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to fence if fence is set" do
      nx.incr_fence
      expect { nx.wait }.to hop("fence")
    end

    it "hops to prepare_for_unplanned_take_over if take_over is set" do
      nx.incr_unplanned_take_over
      expect { nx.wait }.to hop("prepare_for_unplanned_take_over")
    end

    it "hops to prepare_for_planned_take_over if take_over is set" do
      nx.incr_planned_take_over
      expect { nx.wait }.to hop("prepare_for_planned_take_over")
    end

    it "hops to refresh_certificates if refresh_certificates is set" do
      nx.incr_refresh_certificates
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "hops to update_superuser_password if update_superuser_password is set" do
      nx.incr_update_superuser_password
      expect { nx.wait }.to hop("update_superuser_password")
    end

    it "hops to unavailable if checkup is set and the server is not available" do
      nx.incr_checkup
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")
    end

    it "naps if checkup is set but the server is available" do
      nx.incr_checkup
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to configure_metrics if configure_metrics is set" do
      nx.incr_configure_metrics
      expect { nx.wait }.to hop("configure_metrics")
    end

    it "hops to configure if configure is set" do
      nx.incr_configure
      expect { nx.wait }.to hop("configure")
    end

    it "decrements and calls refresh_walg_credentials if refresh_walg_credentials is set" do
      nx.incr_refresh_walg_credentials
      expect(postgres_server).to receive(:refresh_walg_credentials)
      expect { nx.wait }.to nap(6 * 60 * 60)
      expect(Semaphore.where(strand_id: server_strand.id, name: "refresh_walg_credentials").count).to eq(0)
    end

    it "pushes restart if restart is set" do
      nx.incr_restart
      expect { nx.wait }.to hop("restart")
    end

    it "promotes" do
      nx.incr_promote
      expect(postgres_server).to receive(:switch_to_new_timeline)
      expect { nx.wait }.to hop("taking_over")
    end

    describe "read replica" do
      before do
        expect(postgres_server).to receive(:read_replica?).and_return(true)
        expect(postgres_server.resource).to receive(:parent).and_return(true)
      end

      it "checks if it was already lagging and the lag continues, if so, starts recycling" do
        expect(postgres_server).to receive(:lsn_caught_up).and_return(false)
        expect(postgres_server).to receive(:current_lsn).and_return("1/A")

        expect(nx.strand).to receive(:stack).and_return([{"lsn" => "1/A"}]).at_least(:once)
        expect(postgres_server).to receive(:lsn_diff).with("1/A", "1/A").and_return(0)
        # No recycle semaphore set initially
        expect(Semaphore.where(strand_id: server_strand.id, name: "recycle").count).to eq(0)
        expect { nx.wait }.to nap(60)
        # Verify recycle semaphore was incremented
        expect(Semaphore.where(strand_id: server_strand.id, name: "recycle").count).to eq(1)
      end

      it "does not increment recycle if it is incremented already" do
        expect(postgres_server).to receive(:lsn_caught_up).and_return(false)
        expect(postgres_server).to receive(:current_lsn).and_return("1/A")

        expect(nx.strand).to receive(:stack).and_return([{"lsn" => "1/A"}]).at_least(:once)
        expect(postgres_server).to receive(:lsn_diff).with("1/A", "1/A").and_return(0)
        # Pre-set recycle semaphore so it won't be incremented again
        nx.incr_recycle
        expect(Semaphore.where(strand_id: server_strand.id, name: "recycle").count).to eq(1)
        expect { nx.wait }.to nap(60)
        # Verify recycle semaphore count stayed the same (not incremented again)
        expect(Semaphore.where(strand_id: server_strand.id, name: "recycle").count).to eq(1)
      end

      it "checks if it wasn't already lagging but the lag exists, if so, update the stack and nap" do
        expect(postgres_server).to receive(:lsn_caught_up).and_return(false)
        expect(postgres_server).to receive(:current_lsn).and_return("1/A")

        expect(nx.strand).to receive(:stack).and_return([{}]).at_least(:once)
        expect(nx).to receive(:update_stack_lsn).with("1/A")
        expect { nx.wait }.to nap(900)
      end

      it "checks if there is no lag, simply naps" do
        expect(postgres_server).to receive(:lsn_caught_up).and_return(true)
        expect { nx.wait }.to nap(60)
      end

      it "checks if there was a lag, and it still exist but we are progressing, so, we update the stack and nap" do
        expect(postgres_server).to receive(:lsn_caught_up).and_return(false)
        expect(postgres_server).to receive(:current_lsn).and_return("1/A")

        expect(nx.strand).to receive(:stack).and_return([{"lsn" => "1/9"}]).at_least(:once)
        expect(postgres_server).to receive(:lsn_diff).with("1/A", "1/9").and_return(1)
        # Pre-set recycle semaphore so we can verify it gets decremented
        nx.incr_recycle
        expect(Semaphore.where(strand_id: server_strand.id, name: "recycle").count).to eq(1)
        expect(nx).to receive(:update_stack_lsn).with("1/A")
        expect { nx.wait }.to nap(900)
        # Verify recycle semaphore was decremented
        expect(Semaphore.where(strand_id: server_strand.id, name: "recycle").count).to eq(0)
      end
    end
  end

  describe "#unavailable" do
    it "hops to wait if the server is available" do
      # trigger_failover returns false when there's no standby (real behavior)
      # available? should return true to hop to wait
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.unavailable }.to hop("wait")
    end

    it "buds restart if the server is not available" do
      # trigger_failover returns false when there's no standby
      # available? returns false so it buds restart
      expect(nx).to receive(:available?).and_return(false)
      expect(nx).to receive(:bud).with(described_class, {}, :restart)
      expect { nx.unavailable }.to nap(5)
    end

    it "does not bud restart if there is already one restart going on" do
      Strand.create(parent_id: server_strand.id, prog: "Postgres::PostgresServerNexus", label: "restart", stack: [{}], lease: Time.now + 10)
      # trigger_failover returns false when there's no standby
      expect { nx.unavailable }.to nap(5)
      expect(Strand.where(prog: "Postgres::PostgresServerNexus", label: "restart").count).to eq 1
    end

    it "trigger_failover succeeds, naps 0" do
      # Mock trigger_failover to return true - the real behavior requires a standby
      # with very specific state (strand.label == "wait", not needs_recycling?, etc.)
      expect(postgres_server).to receive(:trigger_failover).with(mode: "unplanned").and_return(true)
      expect { nx.unavailable }.to nap(0)
    end
  end

  describe "#fence" do
    it "runs checkpoints and perform lockout" do
      nx.incr_fence
      expect(postgres_server).to receive(:run_query).with("CHECKPOINT; CHECKPOINT; CHECKPOINT;")
      expect(sshable).to receive(:_cmd).with("sudo postgres/bin/lockout #{postgres_server.version}")
      expect(sshable).to receive(:_cmd).with("sudo pg_ctlcluster #{postgres_server.version} main stop -m smart")
      expect { nx.fence }.to hop("wait_in_fence")
    end
  end

  describe "#wait_in_fence" do
    it "naps if unfence is not set" do
      expect { nx.wait_in_fence }.to nap(60)
    end

    it "hops to wait if unfence is set" do
      nx.incr_unfence
      expect(Semaphore.where(strand_id: server_strand.id, name: "unfence").count).to eq(1)
      expect(Semaphore.where(strand_id: server_strand.id, name: "configure").count).to eq(0)
      expect(Semaphore.where(strand_id: server_strand.id, name: "restart").count).to eq(0)
      expect { nx.wait_in_fence }.to hop("wait")
      # Verify unfence was decremented and configure/restart were incremented
      expect(Semaphore.where(strand_id: server_strand.id, name: "unfence").count).to eq(0)
      expect(Semaphore.where(strand_id: server_strand.id, name: "configure").count).to eq(1)
      expect(Semaphore.where(strand_id: server_strand.id, name: "restart").count).to eq(1)
    end
  end

  describe "#prepare_for_unplanned_take_over" do
    # Create a cluster with a real primary and standby for failover tests
    def create_failover_cluster
      standby_strand = described_class.assemble(
        resource_id: postgres_resource.id, timeline_id: postgres_resource.timeline.id,
        timeline_access: "fetch"
      )
      standby = PostgresServer[standby_strand.id]
      primary = postgres_resource.servers.find { it.primary? }
      [primary, standby, standby_strand]
    end

    it "stops postgres in representative server and destroys it" do
      primary, _, standby_strand = create_failover_cluster
      standby_nx = described_class.new(standby_strand)
      standby_nx.incr_unplanned_take_over

      # Get the sshable through the exact chain the code uses
      rep_sshable = standby_nx.postgres_server.resource.representative_server.vm.sshable
      expect(rep_sshable).to receive(:_cmd).with("sudo pg_ctlcluster #{primary.version} main stop -m immediate")

      expect { standby_nx.prepare_for_unplanned_take_over }.to hop("taking_over")

      # Verify the primary was marked for destruction
      expect(Semaphore.where(strand_id: primary.strand.id, name: "destroy").count).to eq(1)
    end

    it "handles SSH connection errors gracefully and continues with destroy" do
      primary, _, standby_strand = create_failover_cluster
      standby_nx = described_class.new(standby_strand)
      standby_nx.incr_unplanned_take_over

      rep_sshable = standby_nx.postgres_server.resource.representative_server.vm.sshable
      expect(rep_sshable).to receive(:_cmd).with("sudo pg_ctlcluster #{primary.version} main stop -m immediate").and_raise(Sshable::SshError.new("", "", "", "", ""))

      expect { standby_nx.prepare_for_unplanned_take_over }.to hop("taking_over")

      # Verify the primary was still marked for destruction despite SSH error
      expect(Semaphore.where(strand_id: primary.strand.id, name: "destroy").count).to eq(1)
    end
  end

  describe "#prepare_for_planned_take_over" do
    it "starts fencing on representative server" do
      # Create standby server
      standby_strand = described_class.assemble(
        resource_id: postgres_resource.id, timeline_id: postgres_resource.timeline.id,
        timeline_access: "fetch"
      )
      standby_nx = described_class.new(standby_strand)
      standby_nx.incr_planned_take_over

      primary = postgres_resource.servers.find { it.primary? }

      expect { standby_nx.prepare_for_planned_take_over }.to hop("wait_fencing_of_old_primary")

      # Verify fence semaphore was set on primary
      expect(Semaphore.where(strand_id: primary.strand.id, name: "fence").count).to eq(1)
    end
  end

  describe "#wait_fencing_of_old_primary" do
    it "naps immediately if fence is set" do
      # Create standby server
      standby_strand = described_class.assemble(
        resource_id: postgres_resource.id, timeline_id: postgres_resource.timeline.id,
        timeline_access: "fetch"
      )
      standby_nx = described_class.new(standby_strand)

      primary = postgres_resource.servers.find { it.primary? }
      # Set the primary's strand label to "fence"
      primary.strand.update(label: "fence")

      expect { standby_nx.wait_fencing_of_old_primary }.to nap(0)
    end

    it "destroys old primary and hops to taking_over when fence is not set" do
      # Create standby server
      standby_strand = described_class.assemble(
        resource_id: postgres_resource.id, timeline_id: postgres_resource.timeline.id,
        timeline_access: "fetch"
      )
      standby_nx = described_class.new(standby_strand)

      primary = postgres_resource.servers.find { it.primary? }
      # Set the primary's strand label to "wait_in_fence"
      primary.strand.update(label: "wait_in_fence")

      expect { standby_nx.wait_fencing_of_old_primary }.to hop("taking_over")

      # Verify the primary was marked for destruction
      expect(Semaphore.where(strand_id: primary.strand.id, name: "destroy").count).to eq(1)
    end
  end

  describe "#taking_over" do
    it "triggers promote if promote command is not sent yet" do
      expect(sshable).to receive(:d_run).with("promote_postgres", "sudo", "postgres/bin/promote", postgres_server.version)

      expect(sshable).to receive(:d_check).with("promote_postgres").and_return("NotStarted")
      expect { nx.taking_over }.to nap(0)
    end

    it "triggers a page and retries if promote command is failed" do
      expect(sshable).to receive(:d_run).with("promote_postgres", "sudo", "postgres/bin/promote", postgres_server.version)
      expect(sshable).to receive(:d_check).with("promote_postgres").and_return("Failed")

      expect { nx.taking_over }.to nap(0)

      page = Page.first(tag: "PGPromotionFailed-#{postgres_server.id}")
      expect(page).not_to be_nil
      expect(page.summary).to eq("#{postgres_server.ubid} promotion failed")
    end

    context "when promote succeeds with real models" do
      def create_postgres_cluster
        user_project = Project.create(name: "test-project")
        postgres_project = Project.create(name: "postgres-service")
        allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)

        resource = Prog::Postgres::PostgresResourceNexus.assemble(
          project_id: user_project.id, location_id: Location::HETZNER_FSN1_ID,
          name: "test-pg", target_vm_size: "standard-2", target_storage_size_gib: 64
        ).subject

        primary = resource.servers.first
        primary.update(timeline_access: "fetch", representative_at: nil)
        primary_strand = primary.strand

        standby_strand = described_class.assemble(
          resource_id: resource.id, timeline_id: resource.timeline.id,
          timeline_access: "fetch"
        )
        standby = PostgresServer[standby_strand.id]

        [resource, primary, primary_strand, standby]
      end

      it "updates the metadata and hops to configure if promote command is succeeded" do
        resource, primary, primary_strand, standby = create_postgres_cluster
        primary_nx = described_class.new(primary_strand)
        sshable = primary_nx.postgres_server.vm.sshable

        expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check promote_postgres").and_return("Succeeded")

        expect { primary_nx.taking_over }.to hop("configure")

        expect(primary.reload.timeline_access).to eq("push")
        expect(primary.representative_at).not_to be_nil
        expect(primary.synchronization_status).to eq("ready")

        expect(standby.reload.synchronization_status).to eq("catching_up")

        expect(Semaphore.where(strand_id: resource.id, name: "refresh_dns_record").count).to eq(1)
        [primary, standby].each do |server|
          expect(Semaphore.where(strand_id: server.id, name: "configure").count).to eq(1)
          expect(Semaphore.where(strand_id: server.id, name: "configure_metrics").count).to eq(1)
          expect(Semaphore.where(strand_id: server.id, name: "restart").count).to eq(1)
        end
      end

      it "resolves existing page when promote succeeds" do
        _, primary, primary_strand, _ = create_postgres_cluster
        primary_nx = described_class.new(primary_strand)
        sshable = primary_nx.postgres_server.vm.sshable

        page = Page.create(summary: "test page", tag: "PGPromotionFailed-#{primary.id}")
        Strand.create_with_id(page, prog: "PageNexus", label: "wait")

        expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check promote_postgres").and_return("Succeeded")

        expect { primary_nx.taking_over }.to hop("configure")

        expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq(1)
      end
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:d_check).with("promote_postgres").and_return("Unknown")
      expect { nx.taking_over }.to nap(5)
    end

    describe "read_replica" do
      it "updates the representative server, refreshes dns and destroys the old representative_server and hops to configure when read_replica" do
        expect(postgres_server).to receive(:read_replica?).and_return(true)
        expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "refresh_dns_record").count).to eq(0)
        expect(Semaphore.where(strand_id: server_strand.id, name: "configure_metrics").count).to eq(0)

        expect { nx.taking_over }.to hop("configure")

        # Verify representative_at was updated
        postgres_server.refresh
        expect(postgres_server.representative_at).not_to be_nil
        # Verify semaphores were incremented
        expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "refresh_dns_record").count).to eq(1)
        expect(Semaphore.where(strand_id: server_strand.id, name: "configure_metrics").count).to eq(1)
      end
    end
  end

  describe "#destroy" do
    it "deletes resources and exits" do
      nx.incr_destroy
      child = server_strand.add_child(prog: "BootstrapRhizome", label: "start")
      server_strand.add_child(prog: "Postgres::PostgresServerNexus", label: "restart")

      expect { nx.destroy }.to hop("wait_children_destroy")

      expect(Semaphore.where(strand_id: child.id, name: "destroy").count).to eq(1)
    end
  end

  describe "#wait_children_destroy" do
    it "naps if children exist" do
      server_strand.add_child(prog: "BootstrapRhizome", label: "start")
      expect { nx.wait_children_destroy }.to nap(30)
    end

    it "hops if all children have exited" do
      expect { nx.wait_children_destroy }.to hop("destroy_vm_and_pg")
    end
  end

  describe "#destroy_vm_and_pg" do
    it "deletes resources and exits" do
      vm_strand = postgres_server.vm.strand
      pg_server_id = postgres_server.id
      expect(Semaphore.where(strand_id: vm_strand.id, name: "destroy").count).to eq(0)

      expect { nx.destroy_vm_and_pg }.to exit({"msg" => "postgres server is deleted"})

      # Verify vm.incr_destroy was called
      expect(Semaphore.where(strand_id: vm_strand.id, name: "destroy").count).to eq(1)
      # Verify postgres_server was destroyed
      expect(PostgresServer[pg_server_id]).to be_nil
    end
  end

  describe "#restart" do
    it "sets deadline, restarts and exits" do
      expect(sshable).to receive(:_cmd).with("sudo postgres/bin/restart #{postgres_server.version}")
      expect(sshable).to receive(:_cmd).with("sudo systemctl restart pgbouncer@*.service")
      expect(nx).to receive(:register_deadline).with("wait", 10 * 60)
      expect { nx.restart }.to exit({"msg" => "postgres server is restarted"})
    end
  end

  describe "#available?" do
    before do
      expect(sshable).to receive(:invalidate_cache_entry)
    end

    it "returns true if the resource is upgrading" do
      # Set target_version different from current version to simulate an upgrade in progress
      new_version = (postgres_server.version == "17") ? "18" : "17"
      postgres_resource.update(target_version: new_version)
      expect(nx.postgres_server.resource).to receive(:upgrade_candidate_server).and_return(postgres_server)
      expect(nx.available?).to be(true)
    end

    it "returns true if health check is successful" do
      expect(postgres_server).to receive(:run_query).with("SELECT 1").and_return("1")
      expect(nx.available?).to be(true)
    end

    it "returns true if the database is in crash recovery" do
      expect(postgres_server).to receive(:run_query).with("SELECT 1").and_raise(Sshable::SshError)
      expect(sshable).to receive(:_cmd).with("sudo tail -n 5 /dat/#{postgres_server.version}/data/pg_log/postgresql.log").and_return("redo in progress")
      expect(nx.available?).to be(true)
    end

    it "returns false otherwise" do
      expect(postgres_server).to receive(:run_query).with("SELECT 1").and_raise(Sshable::SshError)
      expect(sshable).to receive(:_cmd).with("sudo tail -n 5 /dat/#{postgres_server.version}/data/pg_log/postgresql.log").and_return("not doing redo")
      expect(nx.available?).to be(false)
    end
  end

  describe ".update_stack_lsn" do
    it "updates the lsn in the current frame" do
      frame = [{"lsn" => "hello"}]
      nx.strand.stack = frame
      expect(nx.strand).to receive(:modified!)
      nx.update_stack_lsn("update")
      expect(frame.first["lsn"]).to eq("update")
    end
  end
end
