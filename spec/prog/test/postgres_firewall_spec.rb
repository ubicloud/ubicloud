# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::PostgresFirewall do
  subject(:pg_fw_test) { described_class.new(described_class.assemble) }

  let(:test_project) { Project.create(name: "test-project") }
  let(:service_project) { Project.create(name: "service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-fw-subnet", project_id: test_project.id, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64"
    )
  }

  let(:firewall) {
    Firewall.create(name: "test-firewall", project_id: test_project.id, location_id:)
  }

  let(:timeline) { PostgresTimeline.create(location_id:) }

  let(:postgres_resource) {
    pr = PostgresResource.create(
      name: "pg-fw-test",
      superuser_password: "dummy-password",
      ha_type: "none",
      target_version: "17",
      location_id:,
      project_id: test_project.id,
      user_config: {},
      pgbouncer_user_config: {},
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      private_subnet_id: private_subnet.id
    )
    Strand.create_with_id(pr, prog: "Postgres::PostgresResourceNexus", label: "wait")
    pr
  }

  def create_postgres_server
    vm = Prog::Vm::Nexus.assemble_with_sshable(
      test_project.id, name: "pg-fw-vm-#{SecureRandom.hex(4)}", private_subnet_id: private_subnet.id,
      location_id:, unix_user: "ubi"
    ).subject
    server = PostgresServer.create(
      timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
      is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17"
    )
    Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "wait")
    server
  end

  def setup_postgres_resource(with_server: true)
    postgres_resource
    create_postgres_server if with_server
    refresh_frame(pg_fw_test, new_values: {"postgres_resource_id" => postgres_resource.id})
  end

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
  end

  describe ".assemble" do
    it "creates a strand and service projects" do
      st = described_class.assemble
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
    end
  end

  describe "#start" do
    it "creates resource on metal and hops to wait_postgres_resource" do
      expect { pg_fw_test.start }.to hop("wait_postgres_resource")
    end

    it "creates resource on aws and hops to wait_postgres_resource" do
      expect(Config).to receive(:e2e_aws_access_key).and_return("access_key")
      expect(Config).to receive(:e2e_aws_secret_key).and_return("secret_key")
      aws_strand = described_class.assemble(provider: "aws")
      aws_test = described_class.new(aws_strand)
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      LocationAwsAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
      expect { aws_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredential[location.id].access_key).to eq("access_key")
    end

    it "skips creating aws credential if one already exists" do
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      LocationAwsAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
      LocationCredential.create_with_id(location.id, access_key: "existing-key", secret_key: "existing-secret")
      aws_strand = described_class.assemble(provider: "aws")
      aws_test = described_class.new(aws_strand)
      expect { aws_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredential[location.id].access_key).to eq("existing-key")
    end

    it "creates resource on gcp and hops to wait_postgres_resource" do
      expect(Config).to receive(:e2e_gcp_credentials_json).and_return("{}")
      expect(Config).to receive(:e2e_gcp_project_id).and_return("test-project")
      expect(Config).to receive(:e2e_gcp_service_account_email).and_return("test@test.iam.gserviceaccount.com")
      PgGceImage.where(pg_version: "17").each(&:destroy)
      PgGceImage.create_with_id(PgGceImage.generate_uuid,
        gcp_project_id: "test-project",
        gce_image_name: "postgres-ubuntu-2204-x64-20260218",
        pg_version: "17", arch: "x64")
      gcp_strand = described_class.assemble(provider: "gcp")
      gcp_test = described_class.new(gcp_strand)
      expect { gcp_test.start }.to hop("wait_postgres_resource")
    end

    it "skips creating gcp credential if one already exists" do
      gcp_location = Location[provider: "gcp", project_id: nil]
      LocationCredential.create_with_id(gcp_location.id,
        project_id: "existing-project",
        service_account_email: "existing@test.iam.gserviceaccount.com",
        credentials_json: "{}")
      PgGceImage.where(pg_version: "17").each(&:destroy)
      PgGceImage.create_with_id(PgGceImage.generate_uuid,
        gcp_project_id: "existing-project",
        gce_image_name: "postgres-ubuntu-2204-x64-20260218",
        pg_version: "17", arch: "x64")
      gcp_strand = described_class.assemble(provider: "gcp")
      gcp_test = described_class.new(gcp_strand)
      expect { gcp_test.start }.to hop("wait_postgres_resource")
      expect(LocationCredential[gcp_location.id].project_id).to eq("existing-project")
    end
  end

  describe "#wait_postgres_resource" do
    before { setup_postgres_resource }

    let(:sshable) { pg_fw_test.representative_server.vm.sshable }

    it "hops to test_default_firewall_rules if the postgres resource is ready" do
      expect(sshable).to receive(:_cmd).and_return("1\n")
      expect { pg_fw_test.wait_postgres_resource }.to hop("test_default_firewall_rules")
    end

    it "naps for 10 seconds if the postgres resource is not ready" do
      expect(sshable).to receive(:_cmd).and_return("\n")
      expect { pg_fw_test.wait_postgres_resource }.to nap(10)
    end
  end

  describe "#test_default_firewall_rules" do
    before do
      setup_postgres_resource
      allow(pg_fw_test.representative_server.vm).to receive(:ip4_string).and_return("1.2.3.4")
    end

    let(:sshable) { pg_fw_test.representative_server.vm.sshable }

    it "installs netcat, tests connectivity, and hops to test_restricted_firewall_rules" do
      expect(sshable).to receive(:_cmd).with("sudo apt-get update && sudo apt-get install -y netcat-openbsd").ordered
      expect(sshable).to receive(:_cmd).with("nc -zvw 5 1.2.3.4 5432").ordered
      expect { pg_fw_test.test_default_firewall_rules }.to hop("test_restricted_firewall_rules")
    end

    it "sets fail_message if connectivity fails" do
      expect(sshable).to receive(:_cmd).with("sudo apt-get update && sudo apt-get install -y netcat-openbsd").ordered
      expect(sshable).to receive(:_cmd).with("nc -zvw 5 1.2.3.4 5432").and_raise("connection refused").ordered
      expect { pg_fw_test.test_default_firewall_rules }.to hop("test_restricted_firewall_rules")
      expect(frame_value(pg_fw_test, "fail_message")).to include("should have succeeded")
    end
  end

  describe "#test_restricted_firewall_rules" do
    before { setup_postgres_resource }

    it "replaces firewall rules with runner IP and hops to wait_restricted_rules_applied" do
      fw = Firewall.create(name: "#{postgres_resource.ubid}-firewall", project_id: test_project.id, location_id:)
      fw.associate_with_private_subnet(private_subnet, apply_firewalls: false)

      expect(Net::HTTP).to receive(:get).with(URI("https://api.ipify.org")).and_return("100.100.100.100")
      expect { pg_fw_test.test_restricted_firewall_rules }.to hop("wait_restricted_rules_applied")
      expect(frame_value(pg_fw_test, "runner_ip")).to eq("100.100.100.100")
    end
  end

  describe "#wait_restricted_rules_applied" do
    before { setup_postgres_resource }

    let(:sshable) { pg_fw_test.representative_server.vm.sshable }

    it "naps if firewall rules are still being applied" do
      refresh_frame(pg_fw_test, new_values: {"runner_ip" => "100.100.100.100"})
      expect(private_subnet).to receive(:update_firewall_rules_set?).and_return(true)
      allow(pg_fw_test).to receive_messages(postgres_resource: instance_double(
        PostgresResource,
        private_subnet:,
        pg_firewall_rules: []
      ))
      expect { pg_fw_test.wait_restricted_rules_applied }.to nap(5)
    end

    it "verifies rules and hops to test_restore_open_rules when applied" do
      refresh_frame(pg_fw_test, new_values: {"runner_ip" => "100.100.100.100"})

      fw = Firewall.create(name: "#{postgres_resource.ubid}-firewall", project_id: test_project.id, location_id:)
      fw.associate_with_private_subnet(private_subnet, apply_firewalls: false)
      fw.insert_firewall_rule("100.100.100.100/32", Sequel.pg_range(5432..5432))
      fw.insert_firewall_rule("100.100.100.100/32", Sequel.pg_range(6432..6432))
      fw.insert_firewall_rule("1.2.3.4/32", Sequel.pg_range(5432..5432))
      fw.insert_firewall_rule("1.2.3.4/32", Sequel.pg_range(6432..6432))

      allow(pg_fw_test.representative_server.vm).to receive(:ip4_string).and_return("1.2.3.4")
      expect(sshable).to receive(:_cmd).with("nc -zvw 5 1.2.3.4 5432")
      expect { pg_fw_test.wait_restricted_rules_applied }.to hop("test_restore_open_rules")
      expect(frame_value(pg_fw_test, "fail_message")).to be_nil
    end

    it "sets fail_message when firewall CIDRs do not match expected" do
      refresh_frame(pg_fw_test, new_values: {"runner_ip" => "100.100.100.100"})

      fw = Firewall.create(name: "#{postgres_resource.ubid}-firewall", project_id: test_project.id, location_id:)
      fw.associate_with_private_subnet(private_subnet, apply_firewalls: false)
      fw.insert_firewall_rule("200.200.200.200/32", Sequel.pg_range(5432..5432))

      allow(pg_fw_test.representative_server.vm).to receive(:ip4_string).and_return("1.2.3.4")
      expect(sshable).to receive(:_cmd).with("nc -zvw 5 1.2.3.4 5432")
      expect { pg_fw_test.wait_restricted_rules_applied }.to hop("test_restore_open_rules")
      expect(frame_value(pg_fw_test, "fail_message")).to include("Expected firewall CIDRs")
    end
  end

  describe "#test_restore_open_rules" do
    before { setup_postgres_resource }

    it "replaces firewall rules with open rules and hops to wait_open_rules_applied" do
      fw = Firewall.create(name: "#{postgres_resource.ubid}-firewall", project_id: test_project.id, location_id:)
      fw.associate_with_private_subnet(private_subnet, apply_firewalls: false)

      expect { pg_fw_test.test_restore_open_rules }.to hop("wait_open_rules_applied")
    end
  end

  describe "#wait_open_rules_applied" do
    before { setup_postgres_resource }

    let(:sshable) { pg_fw_test.representative_server.vm.sshable }

    it "naps if firewall rules are still being applied" do
      allow(pg_fw_test).to receive_messages(postgres_resource: instance_double(
        PostgresResource,
        private_subnet: instance_double(PrivateSubnet, update_firewall_rules_set?: true, vms: [])
      ))
      expect { pg_fw_test.wait_open_rules_applied }.to nap(5)
    end

    it "verifies connectivity and hops to destroy_postgres" do
      allow(pg_fw_test.representative_server.vm).to receive(:ip4_string).and_return("1.2.3.4")
      expect(sshable).to receive(:_cmd).with("nc -zvw 5 1.2.3.4 5432")
      expect { pg_fw_test.wait_open_rules_applied }.to hop("destroy_postgres")
    end
  end

  describe "#destroy_postgres" do
    before { setup_postgres_resource(with_server: false) }

    it "increments the destroy count and hops to wait_resources_destroyed" do
      expect { pg_fw_test.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(Semaphore.where(strand_id: postgres_resource.id, name: "destroy").count).to eq(1)
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps if the postgres resource isn't deleted yet" do
      setup_postgres_resource(with_server: false)
      expect { pg_fw_test.wait_resources_destroyed }.to nap(5)
    end

    it "naps if the private subnet isn't deleted yet" do
      project_id = pg_fw_test.strand.stack.first["postgres_test_project_id"]
      PrivateSubnet.create(name: "subnet", project_id:, location_id:, net4: "10.0.0.0/26", net6: "fd00::/64")
      expect { pg_fw_test.wait_resources_destroyed }.to nap(5)
    end

    it "verifies timelines are retained and explicitly destroys them" do
      tl = PostgresTimeline.create(location_id:)
      Strand.create_with_id(tl, prog: "Postgres::PostgresTimelineNexus", label: "wait")
      refresh_frame(pg_fw_test, new_values: {"timeline_ids" => [tl.id]})
      expect { pg_fw_test.wait_resources_destroyed }.to nap(5)
      expect(Semaphore.where(strand_id: tl.id, name: "destroy").count).to eq(1)
    end

    it "hops to destroy if the postgres resource destroyed" do
      expect { pg_fw_test.wait_resources_destroyed }.to hop("destroy")
    end
  end

  describe "#destroy" do
    it "exits successfully if no failure happened" do
      expect { pg_fw_test.destroy }.to exit({"msg" => "Postgres firewall tests are finished!"})
    end

    it "hops to failed if a failure happened" do
      pg_fw_test.strand.stack.first["fail_message"] = "Test failed"
      pg_fw_test.strand.modified!(:stack)
      pg_fw_test.strand.save_changes
      fresh_test = described_class.new(pg_fw_test.strand)
      expect { fresh_test.destroy }.to hop("failed")
    end
  end

  describe "#failed" do
    it "naps" do
      expect { pg_fw_test.failed }.to nap(15)
    end
  end

  describe "#test_pg_connection" do
    before { setup_postgres_resource }

    it "sets fail_message when connection succeeds but should_succeed is false" do
      vm = pg_fw_test.representative_server.vm
      allow(vm).to receive(:ip4_string).and_return("1.2.3.4")
      expect(vm.sshable).to receive(:_cmd).with("nc -zvw 5 1.2.3.4 5432")
      pg_fw_test.send(:test_pg_connection, vm, should_succeed: false)
      expect(frame_value(pg_fw_test, "fail_message")).to include("should have been blocked")
    end

    it "does nothing when connection fails and should_succeed is false" do
      vm = pg_fw_test.representative_server.vm
      allow(vm).to receive(:ip4_string).and_return("1.2.3.4")
      expect(vm.sshable).to receive(:_cmd).with("nc -zvw 5 1.2.3.4 5432").and_raise("connection refused")
      pg_fw_test.send(:test_pg_connection, vm, should_succeed: false)
      expect(frame_value(pg_fw_test, "fail_message")).to be_nil
    end
  end
end
