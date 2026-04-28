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
    it "creates a strand at start" do
      st = described_class.assemble
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
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
      expect { nx.wait_postgres_resource }.to hop("destroy_postgres")
      expect(nx.strand.stack.first["fail_message"]).to eq("Failed to seed test data")
    end

    it "hops to take_backup once seeding succeeds" do
      expect(sshable).to receive(:_cmd).and_return("1\n", "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1\n")
      expect { nx.wait_postgres_resource }.to hop("take_backup")
    end
  end

  describe "#take_backup" do
    before { setup_postgres_resource }

    it "kicks off take-backup and records resource+timeline ids" do
      expect(nx.representative_server.vm.sshable).to receive(:_cmd).with(/daemonizer .* take_postgres_backup/)
      expect { nx.take_backup }.to hop("wait_backup")
      stack = nx.strand.stack.first
      expect(stack["original_resource_id"]).to eq(postgres_resource.id)
      expect(stack["timeline_id"]).to eq(timeline.id)
      expect(stack["backup_deadline"]).to be > Time.now.to_i
    end
  end

  describe "#wait_backup" do
    before { setup_postgres_resource }

    let(:sshable) { nx.representative_server.vm.sshable }

    it "forces WAL switch and hops to wait_wal_archive once backup succeeds" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check take_postgres_backup").and_return("Succeeded\n")
      expect(nx.representative_server).to receive(:_run_query).with("SELECT pg_switch_wal()").and_return("0/3000148")
      expect { nx.wait_backup }.to hop("wait_wal_archive")
    end

    it "fails the test if backup daemonizer reports Failed" do
      expect(sshable).to receive(:_cmd).and_return("Failed\n")
      expect { nx.wait_backup }.to hop("destroy_postgres")
      expect(nx.strand.stack.first["fail_message"]).to eq("Backup failed")
    end

    it "fails the test once deadline passes" do
      refresh_frame(nx, new_values: {"backup_deadline" => Time.now.to_i - 1})
      expect(sshable).to receive(:_cmd).and_return("InProgress\n")
      expect { nx.wait_backup }.to hop("destroy_postgres")
      expect(nx.strand.stack.first["fail_message"]).to eq("Backup did not complete in time")
    end

    it "naps while still in progress" do
      refresh_frame(nx, new_values: {"backup_deadline" => Time.now.to_i + 60})
      expect(sshable).to receive(:_cmd).and_return("InProgress\n")
      expect { nx.wait_backup }.to nap(30)
    end
  end

  describe "#wait_wal_archive" do
    before { setup_postgres_resource }

    it "hops to destroy_resource_only once latest_archived_wal_lsn is set" do
      expect(postgres_resource.timeline).to receive(:latest_archived_wal_lsn).and_return("0/3000000")
      expect(nx).to receive(:postgres_resource).and_return(postgres_resource).at_least(:once)
      expect { nx.wait_wal_archive }.to hop("destroy_resource_only")
    end

    it "naps if no archives yet" do
      expect(postgres_resource.timeline).to receive(:latest_archived_wal_lsn).and_return(nil)
      expect(nx).to receive(:postgres_resource).and_return(postgres_resource).at_least(:once)
      expect { nx.wait_wal_archive }.to nap(10)
    end
  end

  describe "#destroy_resource_only" do
    before { setup_postgres_resource }

    it "increments destroy on the resource only, leaving timeline alone" do
      expect { nx.destroy_resource_only }.to hop("wait_resource_destroyed")
      expect(Semaphore.where(strand_id: postgres_resource.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: timeline.strand.id, name: "destroy").count).to eq(0)
    end
  end

  describe "#wait_resource_destroyed" do
    it "naps if the original resource is still around" do
      setup_postgres_resource
      refresh_frame(nx, new_values: {"original_resource_id" => postgres_resource.id})
      expect { nx.wait_resource_destroyed }.to nap(10)
    end

    it "hops to unarchive once the original resource is gone" do
      refresh_frame(nx, new_values: {"original_resource_id" => "00000000-0000-0000-0000-000000000001"})
      expect { nx.wait_resource_destroyed }.to hop("unarchive")
    end
  end

  describe "#unarchive" do
    it "calls unarchive and stores the new resource id" do
      new_strand = instance_double(Strand, id: "11111111-1111-1111-1111-111111111111")
      refresh_frame(nx, new_values: {"original_resource_id" => "00000000-0000-0000-0000-000000000002"})
      expect(Prog::Postgres::PostgresResourceNexus).to receive(:unarchive).with("00000000-0000-0000-0000-000000000002").and_return(new_strand)
      expect { nx.unarchive }.to hop("wait_unarchived")
      expect(nx.strand.stack.first["postgres_resource_id"]).to eq(new_strand.id)
    end
  end

  describe "#wait_unarchived" do
    before { setup_postgres_resource }

    let(:sshable) { nx.representative_server.vm.sshable }

    it "naps if not yet ready" do
      expect(sshable).to receive(:_cmd).and_return("\n")
      expect { nx.wait_unarchived }.to nap(10)
    end

    it "fails the test if read queries don't return seeded data" do
      expect(sshable).to receive(:_cmd).and_return("1\n", "\n")
      expect { nx.wait_unarchived }.to hop("destroy_postgres")
      expect(nx.strand.stack.first["fail_message"]).to eq("Data missing after unarchive")
    end

    it "hops cleanly to destroy_postgres when data is intact" do
      expect(sshable).to receive(:_cmd).and_return("1\n", "4159.90\n415.99\n4.1\n")
      expect { nx.wait_unarchived }.to hop("destroy_postgres")
      expect(nx.strand.stack.first["fail_message"]).to be_nil
    end

    it "naps when the new postgres resource is gone" do
      refresh_frame(nx, new_values: {"postgres_resource_id" => "00000000-0000-0000-0000-000000000001"})
      expect { nx.wait_unarchived }.to nap(10)
    end
  end

  describe "#destroy_postgres" do
    before { setup_postgres_resource }

    it "destroys both the resource and the saved timeline" do
      refresh_frame(nx, new_values: {"timeline_id" => timeline.id})
      expect { nx.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(Semaphore.where(strand_id: postgres_resource.id, name: "destroy").count).to eq(1)
      expect(Semaphore.where(strand_id: timeline.strand.id, name: "destroy").count).to eq(1)
    end

    it "tolerates an already-cleaned-up timeline" do
      refresh_frame(nx, new_values: {"timeline_id" => "00000000-0000-0000-0000-000000000001"})
      expect { nx.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(Semaphore.where(strand_id: postgres_resource.id, name: "destroy").count).to eq(1)
    end

    it "tolerates an already-cleaned-up resource" do
      refresh_frame(nx, new_values: {"postgres_resource_id" => "00000000-0000-0000-0000-000000000001", "timeline_id" => timeline.id})
      expect { nx.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(Semaphore.where(strand_id: timeline.strand.id, name: "destroy").count).to eq(1)
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps if the postgres resource is still around" do
      setup_postgres_resource(with_server: false)
      expect { nx.wait_resources_destroyed }.to nap(5)
    end

    it "naps if the private subnet is still around" do
      project_id = nx.strand.stack.first["postgres_test_project_id"]
      PrivateSubnet.create(name: "subnet", project_id:, location_id:, net4: "10.0.0.0/26", net6: "fd00::/64")
      expect { nx.wait_resources_destroyed }.to nap(5)
    end

    it "hops to finish once everything's gone" do
      expect { nx.wait_resources_destroyed }.to hop("finish")
    end
  end

  describe "#finish" do
    it "exits successfully when nothing failed" do
      expect { nx.finish }.to exit({"msg" => "Postgres unarchive tests are finished!"})
    end

    it "hops to failed when fail_message is set" do
      nx.strand.stack.first["fail_message"] = "boom"
      nx.strand.modified!(:stack)
      nx.strand.save_changes
      fresh = described_class.new(nx.strand)
      expect { fresh.finish }.to hop("failed")
    end
  end

  describe "#failed" do
    it "naps" do
      expect { nx.failed }.to nap(15)
    end
  end
end
