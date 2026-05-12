# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::PostgresServerNexus do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:postgres_timeline) { create_postgres_timeline(location_id:) }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource, timeline: postgres_timeline) }
  let(:st) { postgres_server.strand }
  let(:server) { nx.postgres_server }
  let(:sshable) { server.vm.sshable }
  let(:service_project) { Project.create(name: "postgres-service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-subnet", project:, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64",
    )
  }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
  end

  describe ".assemble" do
    let(:postgres_server) { nil }
    let(:user_project) { Project.create(name: "default") }
    let(:firewall) {
      Firewall.create(name: "#{postgres_resource.ubid}-internal-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: Config.postgres_service_project_id)
    }
    let(:aws_location) {
      loc = Location.create(
        name: "us-west-2",
        display_name: "aws-us-west-2",
        ui_name: "aws-us-west-2",
        visible: true,
        provider: "aws",
        project: user_project,
      )
      LocationCredentialAws.create(
        access_key: "access-key-id",
        secret_key: "secret-access-key",
      ) { it.id = loc.id }
      LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
      loc
    }
    let(:postgres_resource) {
      create_postgres_resource(project: user_project, location_id:)
    }

    it "creates postgres server and vm with sshable" do
      postgres_timeline = create_postgres_timeline(location_id:)
      firewall

      st = described_class.assemble(resource_id: postgres_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", is_representative: true)
      postgres_server = st.subject
      expect(postgres_server).not_to be_nil
      expect(postgres_server.vm).not_to be_nil
      expect(postgres_server.vm.sshable).not_to be_nil

      st = described_class.assemble(resource_id: postgres_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push")
      expect(st.subject.synchronization_status).to eq("catching_up")
    end

    it "creates read replica server with catching_up status even when representative" do
      postgres_timeline = create_postgres_timeline(location_id:)
      firewall
      replica_resource = create_postgres_resource(project: user_project, location_id:)
      replica_resource.update(parent_id: postgres_resource.id)
      Firewall.create(name: "#{replica_resource.ubid}-internal-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: Config.postgres_service_project_id)

      st = described_class.assemble(resource_id: replica_resource.id, timeline_id: postgres_timeline.id, timeline_access: "fetch", is_representative: true)
      expect(st.subject.synchronization_status).to eq("catching_up")
    end

    it "attaches internal firewall to underlying VM, if postgres resource has internal firewall" do
      pg = Prog::Postgres::PostgresResourceNexus.assemble(project_id: user_project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg-name-2", target_vm_size: "standard-2", target_storage_size_gib: 128).subject
      pv = pg.servers.first
      expect(pv.vm.vm_firewalls).to eq [pg.internal_firewall]
    end

    it "picks correct base image for Lantern" do
      lantern_resource = create_postgres_resource(project: user_project, location_id:)
      lantern_resource.update(target_version: "16", flavor: PostgresResource::Flavor::LANTERN)
      Firewall.create(name: "#{lantern_resource.ubid}-internal-firewall", location_id: Location::HETZNER_FSN1_ID, project: service_project)
      postgres_timeline = create_postgres_timeline(location_id:)

      st = described_class.assemble(resource_id: lantern_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", is_representative: true)
      expect(st.subject.vm.boot_image).to eq("postgres16-lantern-ubuntu-2204")
    end

    it "picks correct base image for AWS-pg16" do
      ami = PgAwsAmi[aws_location_name: "us-west-2", pg_version: "16", arch: "x64"]

      aws_resource = create_postgres_resource(project: user_project, location_id: aws_location.id)
      aws_resource.update(target_version: "16")
      Firewall.create(name: "#{aws_resource.ubid}-internal-firewall", location: aws_location, project: service_project)
      postgres_timeline = create_postgres_timeline(location_id: aws_location.id)

      st = described_class.assemble(resource_id: aws_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", is_representative: true)
      expect(st.subject.vm.boot_image).to eq(ami.aws_ami_id)
    end

    it "picks correct base image for AWS-pg17" do
      ami = PgAwsAmi[aws_location_name: "us-west-2", pg_version: "17", arch: "x64"]

      aws_resource = create_postgres_resource(project: user_project, location_id: aws_location.id)
      aws_resource.update(target_version: "17")
      Firewall.create(name: "#{aws_resource.ubid}-internal-firewall", location: aws_location, project: service_project)
      postgres_timeline = create_postgres_timeline(location_id: aws_location.id)

      st = described_class.assemble(resource_id: aws_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", is_representative: true)
      expect(st.subject.vm.boot_image).to eq(ami.aws_ami_id)
    end

    it "sets swap_size_bytes for hobby vm sizes" do
      hobby_resource = create_postgres_resource(project: user_project, location_id:)
      hobby_resource.update(target_vm_size: "hobby-1")
      Firewall.create(name: "#{hobby_resource.ubid}-internal-firewall", location_id:, project: service_project)
      postgres_timeline = create_postgres_timeline(location_id:)

      st = described_class.assemble(resource_id: hobby_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", is_representative: true)
      expect(st.subject.vm.strand.stack.first["swap_size_bytes"]).to eq(4 * 1024 * 1024 * 1024)
    end

    it "picks correct base image for GCP" do
      gcp_location = Location.create(
        name: "us-central1",
        display_name: "gcp-us-central1",
        ui_name: "gcp-us-central1",
        visible: true,
        provider: "gcp",
        project_id: user_project.id,
      )
      LocationCredentialGcp.create_with_id(gcp_location,
        project_id: "test-gcp-project",
        service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
        credentials_json: "{}")
      expect(Config).to receive(:postgres_gce_image_gcp_project_id).and_return("image-hosting-project")
      PgGceImage.where(arch: "x64").destroy
      PgGceImage.create(gce_image_name: "postgres-ubuntu-2204-x64-20260218", arch: "x64", pg_versions: ["16", "17", "18"])
      gcp_resource = PostgresResource.create(
        project: user_project,
        location_id: gcp_location.id,
        name: "pg-gcp16",
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
        superuser_password: "dummy-password",
        target_version: "16",
      )
      Firewall.create(name: "#{gcp_resource.ubid}-internal-firewall", location: gcp_location, project: service_project)
      postgres_timeline = PostgresTimeline.create
      expect(Validation).to receive(:validate_billing_rate)

      st = described_class.assemble(resource_id: gcp_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", is_representative: true)
      expect(st.subject.vm.boot_image).to eq("projects/image-hosting-project/global/images/postgres-ubuntu-2204-x64-20260218")
    end

    it "raises error if the version is not supported for AWS" do
      # Use an AWS location that doesn't have any AMI records
      new_aws_location = Location.create(
        name: "eu-central-1",
        display_name: "aws-eu-central-1",
        ui_name: "aws-eu-central-1",
        visible: true,
        provider: "aws",
        project_id: user_project.id,
      )
      aws_resource = create_postgres_resource(project: user_project, location_id: new_aws_location.id)
      aws_resource.update(target_version: "16")
      postgres_timeline = create_postgres_timeline(location_id: new_aws_location.id)

      expect {
        described_class.assemble(resource_id: aws_resource.id, timeline_id: postgres_timeline.id, timeline_access: "push", is_representative: true)
      }.to raise_error RuntimeError, "No AMI found for PostgreSQL 16 (x64) in eu-central-1"
    end
  end

  describe "#before_run" do
    it "hops to destroy when resource is gone" do
      nx.incr_destroy
      postgres_server.resource.destroy
      expect { nx.before_run }.to hop("destroy")
    end

    it "hops to destroy when resource is destroying" do
      nx.incr_destroy
      postgres_server.resource.incr_destroying
      expect { nx.before_run }.to hop("destroy")
    end

    it "cancels the destroy if the server is the representative of an alive resource" do
      nx.incr_destroy
      expect { nx.before_run }.not_to hop("destroy")
      expect(Semaphore.where(strand_id: postgres_server.id, name: "destroy").count).to eq(0)
    end

    it "cancels the destroy if the server is picked up for take over" do
      nx.incr_destroy
      postgres_server.update(is_representative: false)
      expect(nx.postgres_server).to receive(:taking_over?).and_return(true)
      expect { nx.before_run }.not_to hop("destroy")
      expect(Semaphore.where(strand_id: postgres_server.id, name: "destroy").count).to eq(0)
    end

    it "does not hop to destroy if already destroying" do
      nx.incr_destroy
      nx.incr_destroying
      postgres_server.update(is_representative: false)
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "naps if vm not ready" do
      expect { nx.start }.to nap(5)
    end

    it "update sshable host and hops" do
      postgres_server.vm.strand.update(label: "wait")
      expect { nx.start }.to hop("bootstrap_rhizome")
      expect(Semaphore.where(strand_id: postgres_server.id, name: "initial_provisioning").count).to eq(1)
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds a bootstrap rhizome process" do
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "postgres", "subject_id" => postgres_server.vm.id, "user" => "ubi", "no_bundler_install" => true})
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "hops to mount_data_disk if there are no sub-programs running" do
      expect { nx.wait_bootstrap_rhizome }.to hop("mount_data_disk")
    end

    it "donates if there are sub-programs running" do
      Strand.create(parent: st, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_bootstrap_rhizome }.to nap(5)
    end
  end

  describe "#mount_data_disk" do
    it "formats data disk if format command is not sent yet or failed" do
      expect(server).to receive(:storage_device_paths).and_return(["/dev/vdb"])
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run format_disk sudo mkfs --type ext4 /dev/vdb", {log: true, stdin: nil})

      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check format_disk").and_return("NotStarted")
      expect { nx.mount_data_disk }.to nap(5)
    end

    it "formats data disk correctly when there are multiple storage volumes" do
      expect(server).to receive(:storage_device_paths).and_return(["/dev/nvme1n1", "/dev/nvme2n1"])
      expect(sshable).to receive(:_cmd).with("sudo mdadm --create --verbose /dev/md0 --level=0 --raid-devices=2 /dev/nvme1n1 /dev/nvme2n1")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run format_disk sudo mkfs --type ext4 /dev/md0", {log: true, stdin: nil})

      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check format_disk").and_return("NotStarted")
      expect { nx.mount_data_disk }.to nap(5)
    end

    it "mounts data disk if format disk is succeeded and hops to configure_walg_credentials" do
      expect(server).to receive(:storage_device_paths).and_return(["/dev/vdb"])
      expect(sshable).to receive(:_cmd).with("sudo tune2fs /dev/vdb -r 838860").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check format_disk").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("sudo mkdir -p /dat")
      expect(sshable).to receive(:_cmd).with("sudo common/bin/add_to_fstab /dev/vdb /dat ext4 defaults 0 0")
      expect(sshable).to receive(:_cmd).with("sudo mount /dev/vdb /dat")
      expect { nx.mount_data_disk }.to hop("run_init_script")
    end

    it "mounts data disk correctly when there are multiple storage volumes" do
      expect(server).to receive(:storage_size_gib).and_return(128)
      expect(server).to receive(:storage_device_paths).and_return(["/dev/nvme1n1", "/dev/nvme2n1"])
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check format_disk").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf")
      expect(sshable).to receive(:_cmd).with("sudo update-initramfs -u")
      expect(sshable).to receive(:_cmd).with("sudo tune2fs /dev/md0 -r 1677721").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("sudo mkdir -p /dat")
      expect(sshable).to receive(:_cmd).with("sudo common/bin/add_to_fstab /dev/md0 /dat ext4 defaults 0 0")
      expect(sshable).to receive(:_cmd).with("sudo mount /dev/md0 /dat")
      expect { nx.mount_data_disk }.to hop("run_init_script")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check format_disk").and_return("Unknown")
      expect { nx.mount_data_disk }.to nap(5)
    end
  end

  describe "#run_init_script" do
    it "skips running the init script if not provided" do
      expect(sshable).not_to receive(:_cmd).with("sudo tee /tmp/init_script.sql > /dev/null", anything)
      expect { nx.run_init_script }.to hop("configure_walg_credentials")
    end

    it "runs the init script if provided and is not running already" do
      PostgresInitScript.create_with_id(postgres_resource, init_script: "sudo whoami")
      expect(sshable).to receive(:d_check).with("run_init_script").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("sudo tee postgres/bin/init_script.sh > /dev/null", stdin: "sudo whoami")
      expect(sshable).to receive(:_cmd).with("sudo chmod +x postgres/bin/init_script.sh")
      expect(sshable).to receive(:d_run).with("run_init_script", "./postgres/bin/init_script.sh", "primary", stdin: postgres_resource.name)
      expect { nx.run_init_script }.to nap(5)
    end

    it "naps if init script is still running" do
      PostgresInitScript.create_with_id(postgres_resource, init_script: "sudo whoami")
      expect(sshable).to receive(:d_check).with("run_init_script").and_return("InProgress")
      expect { nx.run_init_script }.to nap(5)
    end

    it "hops to configure_walg_credentials if init script is succeeded" do
      PostgresInitScript.create_with_id(postgres_resource, init_script: "sudo whoami")
      expect(sshable).to receive(:d_check).with("run_init_script").and_return("Succeeded")
      expect { nx.run_init_script }.to hop("configure_walg_credentials")
    end

    it "passes standby role for standby servers" do
      standby_nx = create_standby_nexus
      PostgresInitScript.create_with_id(postgres_resource, init_script: "sudo whoami")
      standby_sshable = standby_nx.postgres_server.vm.sshable
      expect(standby_sshable).to receive(:d_check).with("run_init_script").and_return("NotStarted")
      expect(standby_sshable).to receive(:_cmd).with("sudo tee postgres/bin/init_script.sh > /dev/null", stdin: "sudo whoami")
      expect(standby_sshable).to receive(:_cmd).with("sudo chmod +x postgres/bin/init_script.sh")
      expect(standby_sshable).to receive(:d_run).with("run_init_script", "./postgres/bin/init_script.sh", "standby", stdin: postgres_resource.name)
      expect { standby_nx.run_init_script }.to nap(5)
    end

    it "passes read_replica role for read replica servers" do
      replica_resource = create_read_replica_resource(parent: postgres_resource)
      PostgresInitScript.create_with_id(replica_resource, init_script: "sudo whoami")
      replica_server = create_postgres_server(resource: replica_resource, timeline: postgres_timeline, timeline_access: "fetch", is_representative: true)
      replica_nx = described_class.new(replica_server.strand)
      replica_sshable = replica_nx.postgres_server.vm.sshable
      expect(replica_sshable).to receive(:d_check).with("run_init_script").and_return("NotStarted")
      expect(replica_sshable).to receive(:_cmd).with("sudo tee postgres/bin/init_script.sh > /dev/null", stdin: "sudo whoami")
      expect(replica_sshable).to receive(:_cmd).with("sudo chmod +x postgres/bin/init_script.sh")
      expect(replica_sshable).to receive(:d_run).with("run_init_script", "./postgres/bin/init_script.sh", "read_replica", stdin: replica_resource.name)
      expect { replica_nx.run_init_script }.to nap(5)
    end

    it "passes restore role for PITR restore servers" do
      pitr_resource = PostgresResource.create(
        name: "pg-pitr-#{SecureRandom.hex(4)}",
        superuser_password: "dummy-password",
        ha_type: "none",
        target_version: "16",
        location_id:,
        project:,
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
        restore_target: Time.now,
      )
      PostgresInitScript.create_with_id(pitr_resource, init_script: "sudo whoami")
      pitr_server = create_postgres_server(resource: pitr_resource, timeline: postgres_timeline, timeline_access: "fetch", is_representative: true)
      pitr_nx = described_class.new(pitr_server.strand)
      pitr_sshable = pitr_nx.postgres_server.vm.sshable
      expect(pitr_sshable).to receive(:d_check).with("run_init_script").and_return("NotStarted")
      expect(pitr_sshable).to receive(:_cmd).with("sudo tee postgres/bin/init_script.sh > /dev/null", stdin: "sudo whoami")
      expect(pitr_sshable).to receive(:_cmd).with("sudo chmod +x postgres/bin/init_script.sh")
      expect(pitr_sshable).to receive(:d_run).with("run_init_script", "./postgres/bin/init_script.sh", "restore", stdin: pitr_resource.name)
      expect { pitr_nx.run_init_script }.to nap(5)
    end
  end

  describe "#configure_walg_credentials" do
    it "hops to initialize_empty_database if the server is primary" do
      expect(server).to receive(:refresh_walg_credentials)
      expect(server).to receive(:attach_s3_policy_if_needed)

      expect { nx.configure_walg_credentials }.to hop("initialize_empty_database")
    end

    it "hops to initialize_database_from_backup if the server is not primary" do
      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      standby_nx = described_class.new(standby.strand)
      expect(standby_nx.postgres_server).to receive(:refresh_walg_credentials)
      expect(standby_nx.postgres_server).to receive(:attach_s3_policy_if_needed)

      expect { standby_nx.configure_walg_credentials }.to hop("initialize_database_from_backup")
    end
  end

  describe "#initialize_empty_database" do
    it "triggers initialize_empty_database if initialize_empty_database command is not sent yet or failed" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run initialize_empty_database sudo postgres/bin/initialize-empty-database 17 true", {log: true, stdin: nil}).twice

      # NotStarted
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_empty_database").and_return("NotStarted")
      expect { nx.initialize_empty_database }.to nap(5)

      # Failed
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_empty_database").and_return("Failed")
      expect { nx.initialize_empty_database }.to nap(5)
    end

    it "hops to refresh_certificates if initialize_empty_database command is succeeded" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_empty_database").and_return("Succeeded")
      expect { nx.initialize_empty_database }.to hop("refresh_certificates")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_empty_database").and_return("Unknown")
      expect { nx.initialize_empty_database }.to nap(5)
    end

    it "passes false for strict overcommit when skip_strict_memory_overcommit semaphore is set" do
      postgres_resource.incr_skip_strict_memory_overcommit
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_empty_database").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run initialize_empty_database sudo postgres/bin/initialize-empty-database 17 false", {log: true, stdin: nil})
      expect { nx.initialize_empty_database }.to nap(5)
    end
  end

  describe "#initialize_database_from_backup" do
    it "triggers initialize_database_from_backup if initialize_database_from_backup command is not sent yet or failed" do
      postgres_resource.update(restore_target: Time.now)
      expect(server.timeline).to receive(:latest_backup_label_before_target).and_return("backup-label").twice
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run initialize_database_from_backup sudo postgres/bin/initialize-database-from-backup 17 backup-label true recovery", {log: true, stdin: nil}).twice

      # NotStarted
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_database_from_backup").and_return("NotStarted")
      expect { nx.initialize_database_from_backup }.to nap(5)

      # Failed
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_database_from_backup").and_return("Failed")
      expect { nx.initialize_database_from_backup }.to nap(5)
    end

    it "resolves page, cleans up the stack and hops if initialize_database_from_backup command is succeeded" do
      page = Prog::PageNexus.assemble("#{server.ubid} initialize database from backup failed after 3 attempts",
        ["PGInitializeDatabaseFromBackupFailed", server.id], server.ubid).subject
      refresh_frame(nx, new_values: {"disk_usage" => 1024, "initialize_database_from_backup_try_count" => 3})

      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_database_from_backup").and_return("Succeeded")
      expect { nx.initialize_database_from_backup }.to hop("refresh_certificates")
      expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq(1)

      expect(frame_value(nx, "disk_usage")).to be_nil
      expect(frame_value(nx, "initialize_database_from_backup_try_count")).to be_nil
    end

    it "cleans up the stack and hops when succeeded without an existing page" do
      refresh_frame(nx, new_values: {"disk_usage" => 1024, "initialize_database_from_backup_try_count" => 3})

      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_database_from_backup").and_return("Succeeded")
      expect { nx.initialize_database_from_backup }.to hop("refresh_certificates")

      expect(frame_value(nx, "disk_usage")).to be_nil
      expect(frame_value(nx, "initialize_database_from_backup_try_count")).to be_nil
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_database_from_backup").and_return("Unknown")
      expect { nx.initialize_database_from_backup }.to nap(5)
    end

    it "passes false for strict overcommit when skip_strict_memory_overcommit semaphore is set" do
      postgres_resource.update(restore_target: Time.now)
      postgres_resource.incr_skip_strict_memory_overcommit
      expect(server.timeline).to receive(:latest_backup_label_before_target).and_return("backup-label")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_database_from_backup").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run initialize_database_from_backup sudo postgres/bin/initialize-database-from-backup 17 backup-label false recovery", {log: true, stdin: nil})
      expect { nx.initialize_database_from_backup }.to nap(5)
    end

    it "triggers initialize_database_from_backup with LATEST as backup_label for standbys" do
      server
      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      standby_nx = described_class.new(standby.strand)
      standby_sshable = standby_nx.postgres_server.vm.sshable
      expect(standby_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_database_from_backup").and_return("NotStarted")
      expect(standby_sshable).to receive(:_cmd).with("common/bin/daemonizer2 run initialize_database_from_backup sudo postgres/bin/initialize-database-from-backup 17 LATEST true standby", {log: true, stdin: nil})
      expect { standby_nx.initialize_database_from_backup }.to nap(5)
    end

    it "extends deadline when disk usage increases during InProgress" do
      standby_nx = create_standby_nexus
      standby_sshable = standby_nx.postgres_server.vm.sshable
      expect(standby_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_database_from_backup").and_return("InProgress")
      expect(standby_nx.postgres_server).to receive(:data_disk_usage).and_return(1024000)
      expect(standby_nx).to receive(:register_deadline).with("wait", 10 * 60, allow_extension: 24 * 60 * 60)
      expect { standby_nx.initialize_database_from_backup }.to nap(5)
      expect(frame_value(standby_nx, "disk_usage")).to eq(1024000)
    end

    it "does not extend deadline when disk usage has not increased during InProgress" do
      standby_nx = create_standby_nexus
      standby_sshable = standby_nx.postgres_server.vm.sshable
      refresh_frame(standby_nx, new_values: {"disk_usage" => 2048000})
      expect(standby_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_database_from_backup").and_return("InProgress")
      expect(standby_nx.postgres_server).to receive(:data_disk_usage).and_return(2048000)
      expect(standby_nx).not_to receive(:register_deadline)
      expect { standby_nx.initialize_database_from_backup }.to nap(5)
      expect(frame_value(standby_nx, "disk_usage")).to eq(2048000)
    end

    it "increments try count on Failed" do
      postgres_resource.update(restore_target: Time.now)
      expect(server.timeline).to receive(:latest_backup_label_before_target).and_return("backup-label")
      expect(sshable).to receive(:_cmd).with(/daemonizer2 run/, anything)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_database_from_backup").and_return("Failed")
      expect { nx.initialize_database_from_backup }.to nap(5)
      expect(frame_value(nx, "initialize_database_from_backup_try_count")).to eq(1)
    end

    it "creates a page when try count reaches 3" do
      refresh_frame(nx, new_values: {"initialize_database_from_backup_try_count" => 3})
      postgres_resource.update(restore_target: Time.now)
      expect(server.timeline).to receive(:latest_backup_label_before_target).and_return("backup-label")
      expect(sshable).to receive(:_cmd).with(/daemonizer2 run/, anything)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check initialize_database_from_backup").and_return("Failed")

      expect { nx.initialize_database_from_backup }.to nap(5)
      expect(Page.from_tag_parts("PGInitializeDatabaseFromBackupFailed", server.id)).not_to be_nil
    end
  end

  describe "#refresh_certificates" do
    it "waits for certificate creation by the parent resource" do
      server.resource.update(server_cert: nil)
      expect { nx.refresh_certificates }.to nap(5)
    end

    it "pushes certificates to vm and hops to configure_prometheus during initial provisioning" do
      nx.incr_initial_provisioning
      nx.postgres_server.resource.update(trusted_ca_certs: nil)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/ca.crt > /dev/null", stdin: "client_root_cert_1\nclient_root_cert_2")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/server-ca.crt > /dev/null", stdin: "root_cert_1\nroot_cert_2")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/server.crt > /dev/null", stdin: "server_cert")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/server.key > /dev/null", stdin: "server_cert_key")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/client.crt > /dev/null", stdin: "client_cert")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/client.key > /dev/null", stdin: "client_cert_key")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/ca.crt && sudo chmod 640 /etc/ssl/certs/ca.crt")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/server-ca.crt && sudo chmod 640 /etc/ssl/certs/server-ca.crt")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/server.crt && sudo chmod 640 /etc/ssl/certs/server.crt")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/server.key && sudo chmod 640 /etc/ssl/certs/server.key")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/client.crt && sudo chmod 640 /etc/ssl/certs/client.crt")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/client.key && sudo chmod 640 /etc/ssl/certs/client.key")

      expect(nx.postgres_server).to receive(:refresh_walg_credentials)

      expect { nx.refresh_certificates }.to hop("configure_metrics")
    end

    it "hops to wait at times other than the initial provisioning" do
      server.resource.update(trusted_ca_certs: nil)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/ca.crt > /dev/null", stdin: "client_root_cert_1\nclient_root_cert_2")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/server-ca.crt > /dev/null", stdin: "root_cert_1\nroot_cert_2")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/server.crt > /dev/null", stdin: "server_cert")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/server.key > /dev/null", stdin: "server_cert_key")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/client.crt > /dev/null", stdin: "client_cert")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/ssl/certs/client.key > /dev/null", stdin: "client_cert_key")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/ca.crt && sudo chmod 640 /etc/ssl/certs/ca.crt")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/server-ca.crt && sudo chmod 640 /etc/ssl/certs/server-ca.crt")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/server.crt && sudo chmod 640 /etc/ssl/certs/server.crt")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/server.key && sudo chmod 640 /etc/ssl/certs/server.key")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/client.crt && sudo chmod 640 /etc/ssl/certs/client.crt")
      expect(sshable).to receive(:_cmd).with("sudo chgrp cert_readers /etc/ssl/certs/client.key && sudo chmod 640 /etc/ssl/certs/client.key")
      expect(sshable).to receive(:_cmd).with("sudo -u postgres pg_ctlcluster 17 main reload")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload pgbouncer@*.service")
      expect(server).to receive(:refresh_walg_credentials)
      expect { nx.refresh_certificates }.to hop("wait")
    end
  end

  describe "#configure_metrics" do
    let(:metrics_config) { {interval: "30s", endpoints: ["https://localhost:9100/metrics"], metrics_dir: "/home/ubi/postgres/metrics"} }

    it "configures prometheus and metrics during initial provisioning" do
      nx.incr_initial_provisioning
      expect(sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/web-config.yml > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/prometheus.yml > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now postgres_exporter")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now node_exporter")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now prometheus")

      # Configure metrics expectations
      expect(nx.postgres_server).to receive(:metrics_config).and_return(metrics_config)
      expect(sshable).to receive(:_cmd).with("mkdir -p /home/ubi/postgres/metrics")
      expect(sshable).to receive(:_cmd).with("tee /home/ubi/postgres/metrics/config.json > /dev/null", stdin: metrics_config.to_json)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.service > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.timer > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo mkdir -p /var/lib/node_exporter")
      expect(sshable).to receive(:_cmd).with("sudo chown ubi:ubi /var/lib/node_exporter")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/pg-collect-metrics.service > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/pg-collect-metrics.timer > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now postgres-metrics.timer")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now pg-collect-metrics.timer")

      expect { nx.configure_metrics }.to hop("configure_logs")
    end

    it "configures prometheus and metrics during initial provisioning and hops to setup_cloudwatch if timeline is AWS" do
      # Create an AWS timeline to trigger the cloudwatch path
      aws_location = Location.create(
        name: "us-west-2",
        display_name: "aws-us-west-2",
        ui_name: "aws-us-west-2",
        visible: true,
        provider: "aws",
      )
      aws_timeline = create_postgres_timeline(location_id: aws_location.id)
      server.update(timeline: aws_timeline)

      nx.incr_initial_provisioning
      expect(nx.postgres_server.resource).to receive(:use_old_walg_command_set?).and_return(false)
      expect(sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/web-config.yml > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/prometheus.yml > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now postgres_exporter")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now node_exporter")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now prometheus")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now wal-g")

      # Configure metrics expectations
      expect(nx.postgres_server).to receive(:metrics_config).and_return(metrics_config)
      expect(sshable).to receive(:_cmd).with("mkdir -p /home/ubi/postgres/metrics")
      expect(sshable).to receive(:_cmd).with("tee /home/ubi/postgres/metrics/config.json > /dev/null", stdin: metrics_config.to_json)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.service > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.timer > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo mkdir -p /var/lib/node_exporter")
      expect(sshable).to receive(:_cmd).with("sudo chown ubi:ubi /var/lib/node_exporter")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/pg-collect-metrics.service > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/pg-collect-metrics.timer > /dev/null", stdin: anything)
      expect(sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now postgres-metrics.timer")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now pg-collect-metrics.timer")

      nx.postgres_server.resource.project.set_ff_aws_cloudwatch_logs(true)
      expect { nx.configure_metrics }.to hop("configure_logs")
    end

    it "configures prometheus and metrics and hops to wait at times other than initial provisioning" do
      server
      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      standby_nx = described_class.new(standby.strand)
      standby_server = standby_nx.postgres_server
      standby_sshable = standby_server.vm.sshable

      # Prometheus expectations
      expect(standby_sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/web-config.yml > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/prometheus.yml > /dev/null", stdin: /ubicloud_resource_role: standby/)
      expect(standby_sshable).to receive(:_cmd).with("sudo systemctl reload postgres_exporter || sudo systemctl restart postgres_exporter")
      expect(standby_sshable).to receive(:_cmd).with("sudo systemctl reload node_exporter || sudo systemctl restart node_exporter")
      expect(standby_sshable).to receive(:_cmd).with("sudo systemctl reload prometheus || sudo systemctl restart prometheus")

      # Configure metrics expectations
      expect(standby_server).to receive(:metrics_config).and_return(metrics_config)
      expect(standby_sshable).to receive(:_cmd).with("mkdir -p /home/ubi/postgres/metrics")
      expect(standby_sshable).to receive(:_cmd).with("tee /home/ubi/postgres/metrics/config.json > /dev/null", stdin: metrics_config.to_json)
      expect(standby_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.service > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.timer > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo mkdir -p /var/lib/node_exporter")
      expect(standby_sshable).to receive(:_cmd).with("sudo chown ubi:ubi /var/lib/node_exporter")
      expect(standby_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/pg-collect-metrics.service > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/pg-collect-metrics.timer > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")

      expect { standby_nx.configure_metrics }.to hop("wait")
    end

    it "uses default interval if not specified in config" do
      server
      config_without_interval = {endpoints: ["https://localhost:9100/metrics"], metrics_dir: "/home/ubi/postgres/metrics"}

      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      standby_nx = described_class.new(standby.strand)
      standby_server = standby_nx.postgres_server
      standby_sshable = standby_server.vm.sshable

      # Prometheus expectations
      expect(standby_sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/web-config.yml > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/prometheus.yml > /dev/null", stdin: /ubicloud_resource_role: standby/)
      expect(standby_sshable).to receive(:_cmd).with("sudo systemctl reload postgres_exporter || sudo systemctl restart postgres_exporter")
      expect(standby_sshable).to receive(:_cmd).with("sudo systemctl reload node_exporter || sudo systemctl restart node_exporter")
      expect(standby_sshable).to receive(:_cmd).with("sudo systemctl reload prometheus || sudo systemctl restart prometheus")

      # Configure metrics expectations with default interval
      expect(standby_server).to receive(:metrics_config).and_return(config_without_interval)
      expect(standby_sshable).to receive(:_cmd).with("mkdir -p /home/ubi/postgres/metrics")
      expect(standby_sshable).to receive(:_cmd).with("tee /home/ubi/postgres/metrics/config.json > /dev/null", stdin: config_without_interval.to_json)
      expect(standby_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.service > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.timer > /dev/null", stdin: /OnUnitActiveSec=15s/)
      expect(standby_sshable).to receive(:_cmd).with("sudo mkdir -p /var/lib/node_exporter")
      expect(standby_sshable).to receive(:_cmd).with("sudo chown ubi:ubi /var/lib/node_exporter")
      expect(standby_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/pg-collect-metrics.service > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/pg-collect-metrics.timer > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")

      expect { standby_nx.configure_metrics }.to hop("wait")
    end

    it "includes remote_write config when metric_destinations exist" do
      server
      # Create a metric destination to trigger the map block
      PostgresMetricDestination.create(
        postgres_resource:,
        url: "https://metrics.example.com/write",
        username: "metrics_user",
        password: "metrics_pass",
      )

      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      standby_nx = described_class.new(standby.strand)
      standby_server = standby_nx.postgres_server
      standby_sshable = standby_server.vm.sshable

      # Prometheus expectations
      expect(standby_sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/web-config.yml > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo -u prometheus tee /home/prometheus/prometheus.yml > /dev/null", stdin: /remote_write:.*url:.*metrics\.example\.com/m)
      expect(standby_sshable).to receive(:_cmd).with("sudo systemctl reload postgres_exporter || sudo systemctl restart postgres_exporter")
      expect(standby_sshable).to receive(:_cmd).with("sudo systemctl reload node_exporter || sudo systemctl restart node_exporter")
      expect(standby_sshable).to receive(:_cmd).with("sudo systemctl reload prometheus || sudo systemctl restart prometheus")

      # Configure metrics expectations
      expect(standby_server).to receive(:metrics_config).and_return(metrics_config)
      expect(standby_sshable).to receive(:_cmd).with("mkdir -p /home/ubi/postgres/metrics")
      expect(standby_sshable).to receive(:_cmd).with("tee /home/ubi/postgres/metrics/config.json > /dev/null", stdin: metrics_config.to_json)
      expect(standby_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.service > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/postgres-metrics.timer > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo mkdir -p /var/lib/node_exporter")
      expect(standby_sshable).to receive(:_cmd).with("sudo chown ubi:ubi /var/lib/node_exporter")
      expect(standby_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/pg-collect-metrics.service > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/pg-collect-metrics.timer > /dev/null", stdin: anything)
      expect(standby_sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")

      expect { standby_nx.configure_metrics }.to hop("wait")
    end
  end

  describe "#configure_logs" do
    let(:logs_config) { {instance: "pg123", server_role: "primary", version: "17", log_destinations: []} }

    before do
      allow(nx.postgres_server).to receive(:logs_config).and_return(logs_config)
    end

    it "runs configure-logs when NotStarted" do
      expect(sshable).to receive(:d_check).with("configure_logs").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("configure_logs", "/home/ubi/postgres/bin/configure-logs", stdin: logs_config.to_json)
      expect { nx.configure_logs }.to nap(5)
    end

    it "naps while InProgress" do
      expect(sshable).to receive(:d_check).with("configure_logs").and_return("InProgress")
      expect { nx.configure_logs }.to nap(5)
    end

    it "hops to setup_hugepages after success during initial provisioning" do
      nx.incr_initial_provisioning
      expect(sshable).to receive(:d_check).with("configure_logs").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("configure_logs")
      expect { nx.configure_logs }.to hop("setup_hugepages")
    end

    it "hops to setup_cloudwatch after success during initial provisioning if timeline is AWS" do
      nx.incr_initial_provisioning
      nx.postgres_server.resource.project.set_ff_aws_cloudwatch_logs(true)
      aws_location = Location.create(name: "us-west-2", display_name: "aws-us-west-2", ui_name: "aws-us-west-2", visible: true, provider: "aws")
      aws_timeline = create_postgres_timeline(location_id: aws_location.id)
      server.update(timeline: aws_timeline)
      expect(sshable).to receive(:d_check).with("configure_logs").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("configure_logs")
      expect { nx.configure_logs }.to hop("setup_cloudwatch")
    end

    it "hops to wait after success outside of initial provisioning" do
      expect(sshable).to receive(:d_check).with("configure_logs").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("configure_logs")
      expect { nx.configure_logs }.to hop("wait")
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
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check setup_hugepages").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean setup_hugepages")
      expect { nx.setup_hugepages }.to hop("configure")
    end

    it "retries the setup if it fails" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check setup_hugepages").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run setup_hugepages sudo postgres/bin/setup-hugepages", {log: true, stdin: nil})
      expect { nx.setup_hugepages }.to nap(5)
    end

    it "starts the setup if it is not started" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check setup_hugepages").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run setup_hugepages sudo postgres/bin/setup-hugepages", {log: true, stdin: nil})
      expect { nx.setup_hugepages }.to nap(5)
    end

    it "naps for 5 seconds if the setup is unknown" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check setup_hugepages").and_return("Unknown")
      expect { nx.setup_hugepages }.to nap(5)
    end
  end

  describe "#configure" do
    it "triggers configure if configure command is not sent yet or failed" do
      expect(server).to receive(:configure_hash).and_return("dummy-configure-hash").twice
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run configure_postgres sudo postgres/bin/configure 17", {log: true, stdin: JSON.generate("dummy-configure-hash")}).twice

      # NotStarted
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check configure_postgres").and_return("NotStarted")
      expect { nx.configure }.to nap(5)

      # Failed
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check configure_postgres").and_return("Failed")
      expect { nx.configure }.to nap(5)
    end

    it "handles use_physical_slot semaphore" do
      expect(server).to receive(:configure_hash).and_return("dummy-configure-hash")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check configure_postgres").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run configure_postgres sudo postgres/bin/configure 17", {log: true, stdin: JSON.generate("dummy-configure-hash")})
      server.incr_use_physical_slot
      expect { nx.configure }.to nap(5)
      expect(server.use_physical_slot_set?).to be true
      expect(server.physical_slot_ready_id).to eq server.id
    end

    it "hops to update_superuser_password if configure command is succeeded during the initial provisioning and if the server is primary" do
      nx.incr_initial_provisioning
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean configure_postgres").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check configure_postgres").and_return("Succeeded")
      expect { nx.configure }.to hop("update_superuser_password")
    end

    it "hops to wait_catch_up if configure command is succeeded during the initial provisioning and if the server is standby" do
      server
      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      standby_nx = described_class.new(standby.strand)
      standby_sshable = standby_nx.postgres_server.vm.sshable
      standby_nx.incr_initial_provisioning
      expect(standby_sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean configure_postgres").and_return("Succeeded")
      expect(standby_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check configure_postgres").and_return("Succeeded")
      expect { standby_nx.configure }.to hop("wait_catch_up")
    end

    it "hops to wait_recovery_completion if configure command is succeeded during the initial provisioning and if the server is doing pitr" do
      pitr_resource = create_postgres_resource(project:, location_id:)
      pitr_resource.update(restore_target: Time.now)
      pitr_server = create_postgres_server(resource: pitr_resource, timeline: postgres_timeline, timeline_access: "fetch", is_representative: true)
      pitr_nx = described_class.new(pitr_server.strand)
      pitr_sshable = pitr_nx.postgres_server.vm.sshable
      pitr_nx.incr_initial_provisioning
      expect(pitr_sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean configure_postgres").and_return("Succeeded")
      expect(pitr_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check configure_postgres").and_return("Succeeded")
      expect { pitr_nx.configure }.to hop("wait_recovery_completion")
    end

    it "hops to wait for primaries if configure command is succeeded at times other than the initial provisioning" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean configure_postgres").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check configure_postgres").and_return("Succeeded")
      expect { nx.configure }.to hop("wait")
    end

    it "hops to wait_catch_up for standbys if configure command succeeds at times other than the initial provisioning" do
      server
      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      standby_nx = described_class.new(standby.strand)
      standby_nx.postgres_server.update(synchronization_status: "catching_up")
      standby_sshable = standby_nx.postgres_server.vm.sshable
      expect(standby_sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean configure_postgres").and_return("Succeeded")
      expect(standby_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check configure_postgres").and_return("Succeeded")
      expect { standby_nx.configure }.to hop("wait_catch_up")
    end

    it "hops to wait_catch_up for read replicas if configure command succeeds" do
      replica_resource = create_read_replica_resource(parent: postgres_resource)
      replica_server = create_postgres_server(resource: replica_resource, timeline: postgres_timeline, timeline_access: "fetch", is_representative: true)
      replica_nx = described_class.new(replica_server.strand)
      replica_sshable = replica_nx.postgres_server.vm.sshable
      replica_nx.incr_initial_provisioning
      expect(replica_sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean configure_postgres").and_return("Succeeded")
      expect(replica_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check configure_postgres").and_return("Succeeded")
      expect { replica_nx.configure }.to hop("wait_catch_up")
    end

    it "updates use_physical_slot semaphores on standbys when primary configured" do
      standby_nx = create_standby_nexus(prime_sshable: false)
      standby_nx.postgres_server.update(synchronization_status: "ready")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean configure_postgres").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check configure_postgres").and_return("Succeeded")
      expect { nx.configure }.to hop("wait")
      expect(standby_nx.postgres_server.reload.use_physical_slot_set?).to be true
      expect(standby_nx.postgres_server.configure_set?).to be true
    end

    it "does not update use_physical_slot semaphores on standbys when standby configured" do
      standby_nx = create_standby_nexus(prime_sshable: false)
      standby_nx.postgres_server.update(synchronization_status: "ready")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean configure_postgres").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check configure_postgres").and_return("Succeeded")
      nx.postgres_server.timeline_access = "fetch"
      expect { nx.configure }.to hop("wait")
      expect(standby_nx.postgres_server.reload.use_physical_slot_set?).to be false
      expect(standby_nx.postgres_server.configure_set?).to be false
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check configure_postgres").and_return("Unknown")
      expect { nx.configure }.to nap(5)
    end
  end

  describe "#update_superuser_password" do
    def password_update_sql_matcher
      satisfy { |sql|
        lines = sql.split("\n")
        lines.size == 4 &&
          lines[0] == "BEGIN;" &&
          lines[1] == "SET LOCAL log_statement = 'none';" &&
          lines[2].start_with?("ALTER ROLE postgres WITH PASSWORD 'SCRAM-SHA-256$") &&
          lines[2].end_with?("';") &&
          lines[3] == "COMMIT;"
      }
    end

    it "updates password and hops to run_post_installation_script during initial provisioning" do
      nx.incr_initial_provisioning
      expect(sshable).to receive(:_cmd).with(
        "PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'",
        hash_including(stdin: password_update_sql_matcher),
      ).and_return("")
      expect { nx.update_superuser_password }.to hop("run_post_installation_script")
    end

    it "updates password, installs paradedb packages, and hops to run_post_installation_script during initial provisioning for non-standard flavors" do
      nx.incr_initial_provisioning
      expect(sshable).to receive(:_cmd).with(
        /sudo apt-get install.*pg-analytics.*pg-search/m,
      ).and_return("")
      expect(sshable).to receive(:_cmd).with(
        "PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'",
        hash_including(stdin: password_update_sql_matcher),
      ).and_return("")
      postgres_server.resource.update(flavor: PostgresResource::Flavor::PARADEDB)
      expect { nx.update_superuser_password }.to hop("run_post_installation_script")
    end

    it "updates password and hops to wait at times other than the initial provisioning" do
      expect(sshable).to receive(:_cmd).with(
        "PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'",
        hash_including(stdin: password_update_sql_matcher),
      ).and_return("")
      expect { nx.update_superuser_password }.to hop("wait")
    end
  end

  describe "#run_post_installation_script" do
    it "creates extensions for non-standard flavor and hops wait when succeeded" do
      postgres_server.resource.update(flavor: PostgresResource::Flavor::PARADEDB)
      expect(sshable).to receive(:d_check).with("post_installation_script").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with(
        "PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'",
        hash_including(stdin: /CREATE EXTENSION IF NOT EXISTS pg_cron/),
      ).and_return("")
      expect { nx.run_post_installation_script }.to hop("wait")
    end

    it "skips extension creation for standard flavor and hops wait when succeeded" do
      expect(sshable).to receive(:d_check).with("post_installation_script").and_return("Succeeded")
      expect { nx.run_post_installation_script }.to hop("wait")
    end

    it "starts the post installation script when not started" do
      expect(sshable).to receive(:d_check).with("post_installation_script").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("post_installation_script", "sudo", "postgres/bin/post-installation-script")
      expect { nx.run_post_installation_script }.to nap(1)
    end

    it "starts the post installation script when failed" do
      expect(sshable).to receive(:d_check).with("post_installation_script").and_return("Failed")
      expect(sshable).to receive(:d_run).with("post_installation_script", "sudo", "postgres/bin/post-installation-script")
      expect { nx.run_post_installation_script }.to nap(1)
    end

    it "naps when the post installation script is still running" do
      expect(sshable).to receive(:d_check).with("post_installation_script").and_return("InProgress")
      expect { nx.run_post_installation_script }.to nap(1)
    end
  end

  describe "#wait_catch_up" do
    it "naps if the lag is too high and extends deadline when lsn progresses" do
      expect(server).to receive(:lsn_caught_up).and_return(false)
      expect(server).to receive(:last_known_lsn).and_return("0/1000000")
      expect(nx).to receive(:register_deadline).with("wait", 10 * 60, allow_extension: 24 * 60 * 60)
      expect { nx.wait_catch_up }.to nap(30)
      expect(nx.strand.stack.first["previous_lsn"]).to eq("0/1000000")
    end

    it "naps without extending deadline when lsn has not progressed" do
      nx.strand.stack.first["previous_lsn"] = "0/1000000"
      nx.strand.modified!(:stack)
      nx.strand.save_changes
      expect(server).to receive(:lsn_caught_up).and_return(false)
      expect(server).to receive(:last_known_lsn).and_return("0/1000000")
      expect(server).to receive(:lsn_diff).with("0/1000000", "0/1000000").and_return(0)
      expect(nx).not_to receive(:register_deadline)
      expect { nx.wait_catch_up }.to nap(30)
    end

    it "extends deadline based on disk growth when no lsn has been recorded yet" do
      expect(server).to receive(:lsn_caught_up).and_return(false)
      expect(server).to receive(:last_known_lsn).and_return(nil)
      expect(server).to receive(:data_disk_usage).and_return(1024)
      expect(nx).to receive(:register_deadline).with("wait", 10 * 60, allow_extension: 24 * 60 * 60)
      expect { nx.wait_catch_up }.to nap(30)
      expect(nx.strand.stack.first["previous_disk_usage"]).to eq(1024)
    end

    it "naps without extending deadline when no lsn is available and disk has not grown" do
      nx.strand.stack.first["previous_disk_usage"] = 1024
      nx.strand.modified!(:stack)
      nx.strand.save_changes
      expect(server).to receive(:lsn_caught_up).and_return(false)
      expect(server).to receive(:last_known_lsn).and_return(nil)
      expect(server).to receive(:data_disk_usage).and_return(1024)
      expect(nx).not_to receive(:register_deadline)
      expect { nx.wait_catch_up }.to nap(30)
    end

    it "sets the synchronization_status and hops to wait_synchronization for sync replication" do
      expect(server).to receive(:lsn_caught_up).and_return(true)
      postgres_resource.update(ha_type: PostgresResource::HaType::SYNC)
      expect { nx.wait_catch_up }.to hop("wait_synchronization")
      expect(server.reload.synchronization_status).to eq("ready")
      expect(Semaphore.where(strand_id: server.id, name: "configure").count).to eq(1)
    end

    it "sets the synchronization_status and hops to wait for async replication" do
      expect(server).to receive(:lsn_caught_up).and_return(true)
      postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
      expect { nx.wait_catch_up }.to hop("wait")
      expect(server.reload.synchronization_status).to eq("ready")
      expect(Semaphore.where(strand_id: server.id, name: "configure").count).to eq(1)
    end

    it "hops to wait if replica and caught up, staying in catching_up status" do
      replica_resource = create_read_replica_resource(parent: postgres_resource)
      replica_server = create_postgres_server(resource: replica_resource, timeline: postgres_timeline, timeline_access: "fetch", is_representative: true)
      replica_server.update(synchronization_status: "catching_up")
      replica_nx = described_class.new(replica_server.strand)
      expect(replica_nx.postgres_server).to receive(:lsn_caught_up).and_return(true)
      expect { replica_nx.wait_catch_up }.to hop("wait")
      expect(replica_nx.postgres_server.reload.synchronization_status).to eq("catching_up")
    end
  end

  describe "#wait_synchronization" do
    let(:standby_nx) { @standby_nx }
    let(:representative_sshable) { @representative_sshable }

    before do
      @standby_nx, @representative_sshable = create_standby_nexus(prime_sshable: true)
    end

    it "hops to wait if sync replication is established" do
      expect(representative_sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: anything).and_return("quorum", "sync")
      expect { standby_nx.wait_synchronization }.to hop("wait")
      expect { standby_nx.wait_synchronization }.to hop("wait")
    end

    it "naps if sync replication is not established" do
      expect(representative_sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: anything).and_return("", "async")
      expect { standby_nx.wait_synchronization }.to nap(30)
      expect { standby_nx.wait_synchronization }.to nap(30)
    end
  end

  describe "#wait_recovery_completion" do
    it "naps if it is still in recovery and wal replay is not paused" do
      expect(server).to receive(:_run_query).with("SELECT pg_is_in_recovery()").and_return("t")
      expect(server).to receive(:_run_query).with("SELECT pg_get_wal_replay_pause_state()").and_return("not paused")
      expect { nx.wait_recovery_completion }.to nap(5)
    end

    it "naps if it cannot connect to database due to recovery" do
      expect(server).to receive(:_run_query).with("SELECT pg_is_in_recovery()").and_raise(Sshable::SshError.new("", nil, "Consistent recovery state has not been yet reached.", nil, nil))
      expect { nx.wait_recovery_completion }.to nap(5)
    end

    it "raises error if it cannot connect to database due a problem other than to continueing recovery" do
      expect(server).to receive(:_run_query).with("SELECT pg_is_in_recovery()").and_raise(Sshable::SshError.new("", nil, "Bogus", nil, nil))
      expect { nx.wait_recovery_completion }.to raise_error(Sshable::SshError)
    end

    it "stops wal replay and switches to new timeline if it is still in recovery but wal replay is paused" do
      expect(server).to receive(:_run_query).with("SELECT pg_is_in_recovery()").and_return("t")
      expect(server).to receive(:_run_query).with("SELECT pg_get_wal_replay_pause_state()").and_return("paused")
      expect(server).to receive(:_run_query).with("SELECT pg_wal_replay_resume()")
      expect(server).to receive(:switch_to_new_timeline)

      expect { nx.wait_recovery_completion }.to hop("configure")
    end

    it "switches to new timeline if the recovery is completed" do
      expect(server).to receive(:_run_query).with("SELECT pg_is_in_recovery()").and_return("f")
      expect(server).to receive(:switch_to_new_timeline)
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

    it "hops to lockout if lockout is set" do
      nx.incr_lockout
      expect { nx.wait }.to hop("lockout")
    end

    it "hops to prepare_for_unplanned_take_over if take_over is set" do
      nx.incr_unplanned_take_over
      expect(nx).to receive(:register_deadline).with("wait", 5 * 60)
      expect { nx.wait }.to hop("prepare_for_unplanned_take_over")
    end

    it "hops to prepare_for_planned_take_over if take_over is set" do
      nx.incr_planned_take_over
      expect(nx).to receive(:register_deadline).with("wait", 5 * 60)
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
      expect(nx).to receive(:register_deadline).with("wait", 5 * 60)
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

    it "hops to promote_read_replica if promote_read_replica is set" do
      nx.incr_promote_read_replica
      expect(nx).to receive(:register_deadline).with("wait", 10 * 60)
      expect { nx.wait }.to hop("promote_read_replica")
    end

    it "hops to configure_logs if configure_logs is set" do
      nx.incr_configure_logs
      expect { nx.wait }.to hop("configure_logs")
    end

    it "hops to configure if configure is set" do
      nx.incr_configure
      expect { nx.wait }.to hop("configure")
    end

    it "decrements and calls refresh_walg_credentials if refresh_walg_credentials is set" do
      nx.incr_refresh_walg_credentials
      expect(nx.postgres_server).to receive(:refresh_walg_credentials)
      expect { nx.wait }.to nap(6 * 60 * 60)
      expect(Semaphore.where(strand_id: postgres_server.id, name: "refresh_walg_credentials").count).to eq(0)
    end

    it "decrements and calls attach_s3_policy_if_needed + refresh_walg_credentials if configure_s3_new_timeline is set" do
      nx.incr_configure_s3_new_timeline
      expect(nx.postgres_server).to receive(:attach_s3_policy_if_needed)
      expect(nx.postgres_server).to receive(:refresh_walg_credentials)
      expect { nx.wait }.to nap(6 * 60 * 60)
      expect(Semaphore.where(strand_id: postgres_server.id, name: "configure_s3_new_timeline").count).to eq(0)
    end

    it "decrements restart and unregisters deadline if daemonized restart succeeds" do
      nx.incr_restart
      expect(nx).to receive(:register_deadline).with("complete_restart", 2 * 60)
      expect(nx).to receive(:daemonized_restart).and_return(true)
      expect(nx).to receive(:unregister_deadline).with("complete_restart")
      expect { nx.wait }.to nap(6 * 60 * 60)
      expect(Semaphore.where(strand_id: postgres_server.id, name: "restart").count).to eq(0)
    end

    it "naps without decrementing restart if daemonized restart is not done yet" do
      nx.incr_restart
      expect(nx).to receive(:register_deadline).with("complete_restart", 2 * 60)
      expect(nx).to receive(:daemonized_restart).and_return(false)
      expect { nx.wait }.to nap(1)
      expect(Semaphore.where(strand_id: postgres_server.id, name: "restart").count).to eq(1)
    end

    describe "read replica" do
      let(:replica_resource) { create_read_replica_resource(parent: postgres_resource) }
      let(:replica_server_record) {
        create_postgres_server(resource: replica_resource, timeline: postgres_timeline, timeline_access: "fetch", is_representative: true)
      }
      let(:replica_nx) { described_class.new(replica_server_record.strand) }
      let(:replica_server) { replica_nx.postgres_server }

      it "checks if it was already lagging and the lag continues, if so, starts recycling" do
        expect(replica_server).to receive(:lsn_caught_up).and_return(false)
        expect(replica_server).to receive(:current_lsn).and_return("1/A")

        refresh_frame(replica_nx, new_frame: {"lsn" => "1/A"})
        expect(replica_server).to receive(:lsn_diff).with("1/A", "1/A").and_return(0)
        expect { replica_nx.wait }.to nap(60)
        expect(Semaphore.where(strand_id: replica_server.id, name: "recycle_lagging_read_replica").count).to eq(1)
      end

      it "does not increment recycle if it is incremented already" do
        replica_nx.incr_recycle_lagging_read_replica
        expect(replica_server).to receive(:lsn_caught_up).and_return(false)
        expect(replica_server).to receive(:current_lsn).and_return("1/A")

        refresh_frame(replica_nx, new_frame: {"lsn" => "1/A"})
        expect(replica_server).to receive(:lsn_diff).with("1/A", "1/A").and_return(0)
        expect { replica_nx.wait }.to nap(60)
        expect(Semaphore.where(strand_id: replica_server.id, name: "recycle_lagging_read_replica").count).to eq(1)
      end

      it "checks if it wasn't already lagging but the lag exists, if so, update the stack and nap" do
        expect(replica_server).to receive(:lsn_caught_up).and_return(false)
        expect(replica_server).to receive(:current_lsn).and_return("1/A")

        refresh_frame(replica_nx, new_frame: {})
        expect(replica_nx).to receive(:update_stack_lsn).with("1/A")
        expect { replica_nx.wait }.to nap(900)
      end

      it "checks if there is no lag, simply naps" do
        expect(replica_server).to receive(:lsn_caught_up).and_return(true)
        expect { replica_nx.wait }.to nap(60)
      end

      it "checks if there was a lag, and it still exist but we are progressing, so, we update the stack and nap" do
        expect(replica_server).to receive(:lsn_caught_up).and_return(false)
        expect(replica_server).to receive(:current_lsn).and_return("1/A")

        refresh_frame(replica_nx, new_frame: {"lsn" => "1/9"})
        expect(replica_server).to receive(:lsn_diff).with("1/A", "1/9").and_return(1)
        expect(replica_nx).to receive(:decr_recycle_lagging_read_replica)
        expect(replica_nx).to receive(:update_stack_lsn).with("1/A")
        expect { replica_nx.wait }.to nap(900)
      end
    end
  end

  describe "#unavailable" do
    it "hops to configure if configure is set" do
      nx.incr_configure
      expect { nx.unavailable }.to hop("configure")
    end

    it "hops to lockout if lockout is set" do
      nx.incr_lockout
      expect { nx.unavailable }.to hop("lockout")
    end

    it "hops to wait if the server is available" do
      expect(nx).to receive(:available?).and_return(true)
      expect(nx).to receive(:decr_recycle_unavailable_server)
      expect { nx.unavailable }.to hop("wait")
    end

    it "calls daemonized_restart if the server is not available" do
      expect(nx).to receive(:available?).and_return(false)
      expect(nx).to receive(:daemonized_restart)
      expect { nx.unavailable }.to nap(5)
      expect(postgres_server.reload.recycle_unavailable_server_set?).to be true
    end

    it "calls daemonized_restart without incrementing recycle when recycle is already set" do
      postgres_server.incr_recycle_unavailable_server
      expect(nx).to receive(:available?).and_return(false)
      expect(nx).to receive(:daemonized_restart)
      expect { nx.unavailable }.to nap(5)
      expect(Strand.where(prog: "Postgres::ConvergePostgresResource", label: "start").count).to eq 0
    end

    it "does not create convergence strand if one is already running" do
      Strand.create(prog: "Postgres::ConvergePostgresResource", label: "start", parent_id: postgres_resource.strand.id)
      expect(nx).to receive(:available?).and_return(false)
      expect(nx).to receive(:daemonized_restart)
      expect { nx.unavailable }.to nap(5)
      expect(Strand.where(prog: "Postgres::ConvergePostgresResource", label: "start").count).to eq 1
      expect(postgres_server.reload.recycle_unavailable_server_set?).to be true
    end

    it "trigger_failover succeeds, naps 0" do
      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      standby.strand.update(label: "wait")
      expect(server).to receive(:trigger_failover).with(mode: "unplanned").and_wrap_original do |_m, **|
        standby.incr_unplanned_take_over
        true
      end
      expect { nx.unavailable }.to nap(0)
      expect(Semaphore.where(strand_id: standby.id, name: "unplanned_take_over").count).to eq(1)
    end
  end

  describe "#fence" do
    it "runs checkpoints and perform lockout" do
      expect(nx).to receive(:decr_fence)
      expect(server).to receive(:_run_query).with("CHECKPOINT; CHECKPOINT; CHECKPOINT;")
      expect(sshable).to receive(:_cmd).with("sudo postgres/bin/lockout 17")
      expect(sshable).to receive(:_cmd).with("sudo pg_ctlcluster 17 main stop -m smart")
      expect(sshable).to receive(:_cmd).with("sudo systemctl stop postgres-metrics.timer")
      expect { nx.fence }.to hop("wait_in_fence")
    end

    it "hops to lockout if lockout semaphore is set" do
      nx.incr_lockout
      expect { nx.fence }.to hop("lockout")
    end
  end

  describe "#wait_in_fence" do
    it "naps if unfence is not set" do
      expect { nx.wait_in_fence }.to nap(60)
    end

    it "hops to wait if unfence is set" do
      nx.incr_unfence
      expect { nx.wait_in_fence }.to hop("wait")
      expect(Semaphore.where(strand_id: server.id, name: "unfence").count).to eq(0)
      expect(Semaphore.where(strand_id: server.id, name: "configure").count).to eq(1)
      expect(Semaphore.where(strand_id: server.id, name: "restart").count).to eq(1)
    end
  end

  describe "#prepare_for_unplanned_take_over" do
    let(:standby_nx) { @standby_nx }

    before do
      server
      @standby_nx = create_standby_nexus
    end

    it "increments lockout for primary and hops to wait_representative_lockout" do
      standby_nx.incr_unplanned_take_over
      expect { standby_nx.prepare_for_unplanned_take_over }.to hop("wait_representative_lockout")
      expect(Semaphore.where(strand_id: postgres_server.id, name: "lockout").count).to eq(1)
      expect(Semaphore.where(strand_id: standby_nx.postgres_server.id, name: "unplanned_take_over").count).to eq(0)
    end
  end

  describe "#wait_representative_lockout" do
    let(:standby_nx) { @standby_nx }

    before do
      server
      @standby_nx = create_standby_nexus
    end

    it "hops to taking_over when representative server is in wait_locked_out state" do
      postgres_server.strand.update(label: "wait_locked_out")
      expect { standby_nx.wait_representative_lockout }.to hop("taking_over")
    end

    it "naps when representative server is not in wait_locked_out state" do
      postgres_server.strand.update(label: "wait_lockout_attempt")
      expect { standby_nx.wait_representative_lockout }.to nap(1)
    end
  end

  describe "#lockout" do
    it "buds lockout child programs and hops to wait_lockout_attempt" do
      expect(nx).to receive(:bud).with(Prog::Postgres::PostgresLockout, {"mechanism" => "pg_stop"})
      expect(nx).to receive(:bud).with(Prog::Postgres::PostgresLockout, {"mechanism" => "hba"})
      expect(nx).to receive(:bud).with(Prog::Postgres::PostgresLockout, {"mechanism" => "host_routing"})
      expect { nx.lockout }.to hop("wait_lockout_attempt")
      expect(Semaphore.where(strand_id: server.id, name: "lockout").count).to eq(0)
    end

    it "skips host_routing lockout on cloud providers" do
      gcp_location = Location.create(
        name: "us-central1", display_name: "gcp-us-central1", ui_name: "gcp-us-central1",
        visible: true, provider: "gcp", project:,
      )
      LocationCredentialGcp.create_with_id(gcp_location,
        project_id: "test-project",
        service_account_email: "test@test-project.iam.gserviceaccount.com",
        credentials_json: "{}")
      server.resource.update(location_id: gcp_location.id)

      expect { nx.lockout }.to hop("wait_lockout_attempt")
      child_mechanisms = Strand.where(parent_id: st.id, prog: "Postgres::PostgresLockout").map { it.stack.first["mechanism"] }
      expect(child_mechanisms).to contain_exactly("pg_stop", "hba")
    end
  end

  describe "#wait_lockout_attempt" do
    it "hops to wait_locked_out when lockout succeeds" do
      nx.strand.update(label: "wait_lockout_attempt", stack: [{"lockout_succeeded" => true}])
      expect { nx.wait_lockout_attempt }.to hop("wait_locked_out")
    end

    it "naps when children are still running" do
      Strand.create(parent_id: st.id, prog: "Postgres::PostgresLockout", label: "start", stack: [{"mechanism" => "pg_stop"}])
      expect { nx.wait_lockout_attempt }.to nap(0.5)
    end

    it "updates stack when a child exits with lockout_succeeded and hops to wait_locked_out" do
      Strand.create(parent_id: st.id, prog: "Postgres::PostgresLockout", label: "start", stack: [{"mechanism" => "pg_stop"}])
      child2 = Strand.create(parent_id: st.id, prog: "Postgres::PostgresLockout", label: "start", stack: [{"mechanism" => "hba"}])
      child2.update(exitval: Sequel.pg_jsonb_wrap("lockout_succeeded"))
      expect { nx.wait_lockout_attempt }.to hop("wait_locked_out")
    end

    it "hops to wait_locked_out when all children complete without success" do
      Strand.create(parent_id: st.id, prog: "Postgres::Restart", label: "start", stack: [{}])
      child1 = Strand.create(parent_id: st.id, prog: "Postgres::PostgresLockout", label: "start", stack: [{"mechanism" => "pg_stop"}])
      child2 = Strand.create(parent_id: st.id, prog: "Postgres::PostgresLockout", label: "start", stack: [{"mechanism" => "hba"}])
      child1.update(exitval: Sequel.pg_jsonb_wrap("lockout_failed"))
      child2.update(exitval: Sequel.pg_jsonb_wrap("lockout_failed"))
      expect { nx.wait_lockout_attempt }.to hop("wait_locked_out")
    end
  end

  describe "#wait_locked_out" do
    it "naps for 24 hours" do
      expect { nx.wait_locked_out }.to nap(24 * 60 * 60)
    end
  end

  describe "#prepare_for_planned_take_over" do
    before do
      @standby_nx = create_standby_nexus
    end

    it "starts fencing on representative server" do
      @standby_nx.incr_planned_take_over
      expect { @standby_nx.prepare_for_planned_take_over }.to hop("wait_fencing_of_old_primary")
      expect(Semaphore.where(strand_id: @standby_nx.postgres_server.id, name: "planned_take_over").count).to eq(0)
      expect(Semaphore.where(strand_id: postgres_server.id, name: "fence").count).to eq(1)
    end
  end

  describe "#wait_fencing_of_old_primary" do
    before do
      @standby_nx = create_standby_nexus
    end

    it "hops to taking_over when representative server is in wait_in_fence state" do
      postgres_server.strand.update(label: "wait_in_fence")
      expect { @standby_nx.wait_fencing_of_old_primary }.to hop("taking_over")
    end

    it "naps when representative server is not in wait_in_fence state" do
      postgres_server.strand.update(label: "fence")
      expect { @standby_nx.wait_fencing_of_old_primary }.to nap(1)
    end

    it "falls back to unplanned failover when deadline has passed" do
      postgres_server.strand.update(label: "fence")
      @standby_nx.strand.update(stack: [{"deadline_at" => (Time.now - 1).to_s, "deadline_target" => "wait"}])
      expect { @standby_nx.wait_fencing_of_old_primary }.to hop("wait_representative_lockout")
      expect(Semaphore.where(strand_id: postgres_server.id, name: "lockout").count).to eq(1)
    end
  end

  describe "#promote_read_replica" do
    it "runs promote command if not started yet" do
      expect(sshable).to receive(:d_check).with("promote_postgres").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("promote_postgres", "sudo", "postgres/bin/promote", "17")
      expect { nx.promote_read_replica }.to nap(5)
    end

    it "retries promote command if previous run failed" do
      expect(sshable).to receive(:d_check).with("promote_postgres").and_return("Failed")
      expect(sshable).to receive(:d_run).with("promote_postgres", "sudo", "postgres/bin/promote", "17")
      expect { nx.promote_read_replica }.to nap(5)
    end

    it "cleans up and hops to configure when Succeeded" do
      expect(sshable).to receive(:d_check).with("promote_postgres").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("promote_postgres")
      expect { nx.promote_read_replica }.to hop("configure")
      expect(Semaphore.where(strand_id: postgres_server.id, name: "configure").count).to eq(1)
      expect(Semaphore.where(strand_id: postgres_server.id, name: "configure_metrics").count).to eq(1)
    end

    it "naps if promote command is still running" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check promote_postgres").and_return("Unknown")
      expect { nx.promote_read_replica }.to nap(5)
    end
  end

  describe "#taking_over" do
    it "triggers promote if promote command is not sent yet" do
      expect(sshable).to receive(:d_run).with("promote_postgres", "sudo", "postgres/bin/promote", "17")

      expect(sshable).to receive(:d_check).with("promote_postgres").and_return("NotStarted")
      expect { nx.taking_over }.to nap(0)
    end

    it "retries if promote command is failed" do
      expect(sshable).to receive(:d_run).with("promote_postgres", "sudo", "postgres/bin/promote", "17")

      expect(sshable).to receive(:d_check).with("promote_postgres").and_return("Failed")
      expect { nx.taking_over }.to nap(0)
    end

    it "updates the metadata and hops to configure if promote command is succeeded" do
      postgres_server
      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      standby_nx = described_class.new(standby.strand)
      standby_sshable = standby_nx.postgres_server.vm.sshable

      expect(standby_sshable).to receive(:d_check).with("promote_postgres").and_return("Succeeded")

      expect { standby_nx.taking_over }.to hop("configure")

      postgres_server.reload
      expect(Semaphore.where(strand_id: postgres_server.id, name: "destroy").count).to eq(1)

      standby.reload
      expect(standby.timeline_access).to eq("push")
      expect(standby.is_representative).to be true
      expect(standby.synchronization_status).to eq("ready")

      expect(Semaphore.where(strand_id: postgres_resource.id, name: "refresh_dns_record").count).to eq(1)

      [postgres_server, standby].each do |server|
        expect(Semaphore.where(strand_id: server.id, name: "configure").count).to eq(1)
        expect(Semaphore.where(strand_id: server.id, name: "configure_metrics").count).to eq(1)
      end
    end

    it "resolves existing page, updates the metadata and hops to configure if promote command is succeeded" do
      postgres_server
      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      standby_nx = described_class.new(standby.strand)
      standby_sshable = standby_nx.postgres_server.vm.sshable

      page = Prog::PageNexus.assemble(
        "#{standby.ubid} promotion failed",
        ["PGPromotionFailed", standby.id],
        standby.ubid,
      ).subject
      expect(standby_sshable).to receive(:d_check).with("promote_postgres").and_return("Succeeded")

      expect { standby_nx.taking_over }.to hop("configure")

      postgres_server.reload
      expect(Semaphore.where(strand_id: postgres_server.id, name: "destroy").count).to eq(1)

      standby.reload
      expect(standby.timeline_access).to eq("push")
      expect(standby.is_representative).to be true
      expect(standby.synchronization_status).to eq("ready")

      expect(Semaphore.where(strand_id: postgres_resource.id, name: "refresh_dns_record").count).to eq(1)

      [postgres_server, standby].each do |server|
        expect(Semaphore.where(strand_id: server.id, name: "configure").count).to eq(1)
        expect(Semaphore.where(strand_id: server.id, name: "configure_metrics").count).to eq(1)
      end

      expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq(1)
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check promote_postgres").and_return("Unknown")
      expect { nx.taking_over }.to nap(5)
    end

    describe "read_replica" do
      it "updates the representative server, refreshes dns and destroys the old representative_server and hops to configure when read_replica" do
        replica_resource = create_read_replica_resource(parent: postgres_resource)
        replica_server = create_postgres_server(resource: replica_resource, timeline: postgres_timeline, timeline_access: "fetch", is_representative: true)
        replica_server.update(synchronization_status: "catching_up")
        replica_nx = described_class.new(replica_server.strand)

        expect { replica_nx.taking_over }.to hop("configure")
        expect(replica_server.reload.is_representative).to be true
        expect(replica_server.synchronization_status).to eq("ready")
        expect(Semaphore.where(strand_id: replica_resource.id, name: "refresh_dns_record").count).to eq(1)
        expect(Semaphore.where(strand_id: replica_server.id, name: "configure_metrics").count).to eq(1)
      end
    end
  end

  describe "#destroy" do
    it "deletes resources and exits" do
      child = st.add_child(prog: "BootstrapRhizome", label: "start")
      pg_server_child = st.add_child(prog: "Postgres::PostgresServerNexus", label: "restart")

      expect { nx.destroy }.to hop("wait_children_destroy")

      expect(Semaphore.where(strand_id: child.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: pg_server_child.id, name: "destroy").count).to eq(0)
    end
  end

  describe "#wait_children_destroy" do
    it "naps if children exist" do
      st.add_child(prog: "BootstrapRhizome", label: "start")
      expect { nx.wait_children_destroy }.to nap(30)
    end

    it "hops if all children have exited" do
      expect { nx.wait_children_destroy }.to hop("destroy_vm_and_pg")
    end
  end

  describe "#destroy_vm_and_pg" do
    before do
      expect(sshable).to receive(:_cmd).with("sudo dmesg --time-format iso | tail -200", hash_including(log: false)).and_return("")
    end

    it "deletes resources and exits" do
      vm = postgres_server.vm

      expect { nx.destroy_vm_and_pg }.to exit({"msg" => "postgres server is deleted"})

      expect(Semaphore.where(strand_id: vm.id, name: "destroy").count).to eq(1)
      expect(postgres_server.exists?).to be false
    end

    it "increments configure on the representative server when it is a different server" do
      postgres_server.update(is_representative: false)
      representative_server = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: true)

      expect { nx.destroy_vm_and_pg }.to exit({"msg" => "postgres server is deleted"})

      expect(Semaphore.where(strand_id: representative_server.id, name: "configure").count).to eq(1)
    end

    it "does not crash when this server is the representative server" do
      # postgres_server is the representative server (is_representative: true by default)
      expect { nx.destroy_vm_and_pg }.to exit({"msg" => "postgres server is deleted"})
    end

    it "does not crash when the resource is already deleted" do
      allow(nx).to receive(:resource).and_return(nil)
      expect { nx.destroy_vm_and_pg }.to exit({"msg" => "postgres server is deleted"})
    end
  end

  describe "#destroy_vm_and_pg rescue" do # split out from #destroy_vm_and_pg to opt-out of before
    it "proceeds when dmesg raises an SSH error" do
      expect(sshable).to receive(:_cmd).with("sudo dmesg --time-format iso | tail -200", hash_including(log: false)).and_raise(Sshable::SshError.new("cmd", "", "", 1, nil))
      expect { nx.destroy_vm_and_pg }.to exit({"msg" => "postgres server is deleted"})
    end
  end

  describe "#available?" do
    before do
      expect(sshable).to receive(:invalidate_cache_entry)
    end

    it "returns true if the resource is upgrading" do
      postgres_resource.update(target_version: "18")
      expect(server.resource).to receive(:upgrade_candidate_server).and_return(server)
      expect(nx.available?).to be(true)
    end

    it "returns true if health check is successful" do
      expect(server).to receive(:_run_query).with("SELECT 1").and_return("1")
      expect(nx.available?).to be(true)
    end

    it "returns true if the database is in crash recovery" do
      expect(server).to receive(:_run_query).with("SELECT 1").and_raise(Sshable::SshError)
      expect(sshable).to receive(:_cmd).with(a_string_matching(/find.*-mmin -5.*tail -n 50.*grep.*redo in progress/)).and_return("redo in progress")
      expect(nx.available?).to be(true)
    end

    it "returns false otherwise" do
      expect(server).to receive(:_run_query).with("SELECT 1").and_raise(Sshable::SshError)
      expect(sshable).to receive(:_cmd).with(a_string_matching(/find.*-mmin -5.*tail -n 50.*grep.*redo in progress/)).and_return("")
      expect(nx.available?).to be(false)
    end

    it "returns false if both health check and log check raise" do
      expect(server).to receive(:_run_query).with("SELECT 1").and_raise(Sshable::SshError)
      expect(sshable).to receive(:_cmd).with(a_string_matching(/find.*-mmin -5.*tail -n 50.*grep.*redo in progress/)).and_raise(Sshable::SshError)
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

  describe "#daemonized_restart" do
    it "cleans up and returns true when restart succeeded" do
      expect(sshable).to receive(:d_check).with("postgres_restart").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("postgres_restart")
      expect(nx.daemonized_restart).to be true
    end

    it "starts the restart and returns false when not started" do
      expect(sshable).to receive(:d_check).with("postgres_restart").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("postgres_restart", "sudo", "postgres/bin/restart", postgres_server.version)
      expect(nx.daemonized_restart).to be false
    end

    it "starts the restart and returns false when failed" do
      expect(sshable).to receive(:d_check).with("postgres_restart").and_return("Failed")
      expect(sshable).to receive(:d_run).with("postgres_restart", "sudo", "postgres/bin/restart", postgres_server.version)
      expect(nx.daemonized_restart).to be false
    end

    it "returns false when restart is in progress" do
      expect(sshable).to receive(:d_check).with("postgres_restart").and_return("InProgress")
      expect(nx.daemonized_restart).to be false
    end
  end
end
