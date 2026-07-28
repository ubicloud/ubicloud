# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::UnarchivePostgresResource do
  subject(:nx) { described_class.new(described_class.assemble) }

  let(:test_project) { Project.create(name: "test-project") }
  let(:service_project) { Project.create(name: "service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:timeline) { create_postgres_timeline(location_id:) }
  let(:postgres_resource) { create_postgres_resource(project: test_project, location_id:) }

  def setup_postgres_resource(with_server: true)
    postgres_resource
    postgres_resource.strand.update(label: "wait")
    create_postgres_server(resource: postgres_resource, timeline:).strand.update(label: "wait") if with_server
    refresh_frame(nx, new_values: {"postgres_resource_id" => postgres_resource.id})
  end

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
  end

  describe ".assemble" do
    it "creates a strand at start with its test project" do
      st = described_class.assemble
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
      expect(Project[name: "Postgres-Unarchive-Test-Project"]).not_to be_nil
    end
  end

  describe "#start" do
    it "assembles a postgres resource and hops to wait_postgres_resource" do
      expect { nx.start }.to hop("wait_postgres_resource")
      expect(nx.strand.stack.first["postgres_resource_id"]).not_to be_nil
    end
  end

  describe "#wait_postgres_resource" do
    before { setup_postgres_resource }

    let(:sshable) { nx.representative_server.vm.sshable }

    it "naps if the postgres resource is not ready" do
      expect(sshable).to receive(:_cmd).and_return("\n")
      expect { nx.wait_postgres_resource }.to nap(10)
    end

    it "fails the test if seeding queries fail" do
      expect(sshable).to receive(:_cmd).and_return("1\n", "\n")
      expect { nx.wait_postgres_resource }.to hop("destroy")
      expect(nx.strand.stack.first["fail_message"]).to eq("Failed to seed test data")
    end

    it "hops to take_backup once seeding succeeds" do
      expect(sshable).to receive(:_cmd).and_return("1\n", "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1\n")
      expect { nx.wait_postgres_resource }.to hop("take_backup")
    end
  end

  describe "#take_backup" do
    before { setup_postgres_resource }

    it "records the originals, requests a backup, and hops to wait_backup" do
      expect { nx.take_backup }.to hop("wait_backup")
      stack = nx.strand.stack.first
      expect(stack["original_resource_id"]).to eq(postgres_resource.id)
      expect(stack["original_timeline_id"]).to eq(timeline.id)
      expect(stack["backup_deadline"]).to be > Time.now.to_i
      expect(Semaphore.where(strand_id: timeline.id, name: "take_backup_for_converge").count).to eq(1)
    end
  end

  describe "#wait_backup" do
    before do
      setup_postgres_resource
      refresh_frame(nx, new_values: {"original_timeline_id" => timeline.id, "backup_deadline" => Time.now.to_i + 600})
    end

    let(:sshable) { nx.representative_server.vm.sshable }

    it "switches WAL and hops to wait_wal_archive once a backup exists" do
      expect(nx.original_timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster))
      expect(nx.original_timeline).to receive(:list_objects).with("basebackups_005/", delimiter: "/")
        .and_return([instance_double(Minio::Client::Blob, key: "basebackups_005/0001_backup_stop_sentinel.json")])
      expect(sshable).to receive(:_cmd).and_return("0/3000148\n")
      expect { nx.wait_backup }.to hop("wait_wal_archive")
    end

    it "fails the test once the deadline passes" do
      refresh_frame(nx, new_values: {"backup_deadline" => Time.now.to_i - 1})
      expect { nx.wait_backup }.to hop("destroy")
      expect(nx.strand.stack.first["fail_message"]).to eq("Backup did not complete in time")
    end

    it "naps while the backup is still in progress" do
      expect { nx.wait_backup }.to nap(30)
    end
  end

  describe "#wait_wal_archive" do
    before do
      setup_postgres_resource
      refresh_frame(nx, new_values: {"original_timeline_id" => timeline.id})
    end

    it "destroys only the resource once WAL is archived" do
      expect(PostgresTimeline).to receive(:any_archived_wal?).with(timeline).and_return(true)
      expect { nx.wait_wal_archive }.to hop("wait_original_destroyed")
      expect(Semaphore.where(strand_id: postgres_resource.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: timeline.id, name: "destroy").count).to eq(0)
    end

    it "naps if no WAL segment is archived yet" do
      expect(PostgresTimeline).to receive(:any_archived_wal?).with(timeline).and_return(false)
      expect { nx.wait_wal_archive }.to nap(10)
    end
  end

  describe "#wait_original_destroyed" do
    it "naps if the original resource is still around" do
      setup_postgres_resource
      refresh_frame(nx, new_values: {"original_resource_id" => postgres_resource.id})
      expect { nx.wait_original_destroyed }.to nap(10)
    end

    it "hops to unarchive once the original resource is gone" do
      refresh_frame(nx, new_values: {"original_resource_id" => "00000000-0000-0000-0000-000000000001"})
      expect { nx.wait_original_destroyed }.to hop("unarchive")
    end
  end

  describe "#unarchive" do
    it "unarchives and adopts the restored resource" do
      restored = create_postgres_resource(project: test_project, location_id:)
      subnet = PrivateSubnet.create(name: "restored-subnet", project_id: test_project.id, location_id:, net4: "10.9.0.0/26", net6: "fd00::/64")
      restored.update(private_subnet_id: subnet.id)
      refresh_frame(nx, new_values: {"original_resource_id" => "00000000-0000-0000-0000-000000000002"})
      expect(Prog::Postgres::PostgresResourceNexus).to receive(:unarchive).with("00000000-0000-0000-0000-000000000002").and_return(restored.strand)
      expect { nx.unarchive }.to hop("wait_unarchived")
      stack = nx.strand.stack.first
      expect(stack["postgres_resource_id"]).to eq(restored.id)
      expect(stack["private_subnet_id"]).to eq(subnet.id)
    end
  end

  describe "#wait_unarchived" do
    before { setup_postgres_resource }

    let(:sshable) { nx.representative_server.vm.sshable }

    it "naps if the restored resource is not ready" do
      expect(sshable).to receive(:_cmd).and_return("\n")
      expect { nx.wait_unarchived }.to nap(10)
    end

    it "fails the test if read queries don't return the seeded data" do
      expect(sshable).to receive(:_cmd).and_return("1\n", "\n")
      expect { nx.wait_unarchived }.to hop("destroy")
      expect(nx.strand.stack.first["fail_message"]).to eq("Data missing after unarchive")
    end

    it "hops cleanly to destroy when data is intact" do
      expect(sshable).to receive(:_cmd).and_return("1\n", "4159.90\n415.99\n4.1\n")
      expect { nx.wait_unarchived }.to hop("destroy")
      expect(nx.strand.stack.first["fail_message"]).to be_nil
    end
  end

  describe "#destroy_postgres" do
    let(:original_timeline) { create_postgres_timeline(location_id:) }

    it "collects the original and current timelines and destroys the resource" do
      setup_postgres_resource
      refresh_frame(nx, new_values: {"original_timeline_id" => original_timeline.id})
      expect { nx.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(nx.strand.stack.first["timeline_ids"]).to contain_exactly(original_timeline.id, timeline.id)
      expect(Semaphore.where(strand_id: postgres_resource.id, name: "destroy").count).to eq(1)
    end

    it "tolerates an already-destroyed resource" do
      refresh_frame(nx, new_values: {"postgres_resource_id" => "00000000-0000-0000-0000-000000000001", "original_timeline_id" => original_timeline.id})
      expect { nx.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(nx.strand.stack.first["timeline_ids"]).to eq([original_timeline.id])
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps if the postgres resource is still around" do
      setup_postgres_resource(with_server: false)
      expect { nx.wait_resources_destroyed }.to nap(5)
    end

    it "naps if the private subnet is still around" do
      subnet = PrivateSubnet.create(name: "subnet", project_id: test_project.id, location_id:, net4: "10.0.0.0/26", net6: "fd00::/64")
      refresh_frame(nx, new_values: {"private_subnet_id" => subnet.id, "timeline_ids" => []})
      expect { nx.wait_resources_destroyed }.to nap(5)
    end

    it "requests destruction of retained timelines and naps" do
      refresh_frame(nx, new_values: {"timeline_ids" => [timeline.id]})
      expect { nx.wait_resources_destroyed }.to nap(5)
      expect(Semaphore.where(strand_id: timeline.id, name: "destroy").count).to eq(1)
    end

    it "hops to finish once everything is gone" do
      refresh_frame(nx, new_values: {"timeline_ids" => ["00000000-0000-0000-0000-000000000001"]})
      expect { nx.wait_resources_destroyed }.to hop("finish")
    end
  end
end
