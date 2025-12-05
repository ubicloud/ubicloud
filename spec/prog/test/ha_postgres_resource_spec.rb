# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::HaPostgresResource do
  subject(:pgr_test) { described_class.new(described_class.assemble) }

  let(:postgres_service_project_id) { "546a1ed8-53e5-86d2-966c-fb782d2ae3ab" }
  let(:working_representative_server) { instance_double(PostgresServer, run_query: "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1") }
  let(:faulty_representative_server) { instance_double(PostgresServer, run_query: "") }
  let(:vm) { instance_double(Vm, sshable: Sshable.new) }
  let(:servers) { [instance_double(PostgresServer, ubid: "1234", timeline_access: "push", vm: vm), instance_double(PostgresServer, ubid: "5678", timeline_access: "fetch", vm: vm)] }
  let(:servers_after_failover) { [instance_double(PostgresServer, ubid: "5678", timeline_access: "push", vm: vm), instance_double(PostgresServer, ubid: "9012", timeline_access: "fetch", vm: vm)] }

  describe ".assemble" do
    it "creates a strand and service projects" do
      expect(Config).to receive(:postgres_service_project_id).exactly(2).and_return(postgres_service_project_id)
      st = described_class.assemble
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
    end
  end

  describe "#start" do
    it "hops to wait_minio_cluster" do
      expect(Prog::Minio::MinioClusterNexus).to receive(:assemble).and_return(instance_double(Strand, id: "1234"))
      expect { pgr_test.start }.to hop("wait_minio_cluster")
    end
  end

  describe "#wait_minio_cluster" do
    it "naps for 10 seconds if the minio cluster is not ready" do
      expect(pgr_test).to receive(:minio_cluster).and_return(instance_double(MinioCluster, strand: instance_double(Strand, label: "start")))
      expect { pgr_test.wait_minio_cluster }.to nap(10)
    end

    it "hops to create_postgres_resource if the minio cluster is ready" do
      expect(pgr_test).to receive(:minio_cluster).and_return(instance_double(MinioCluster, strand: instance_double(Strand, label: "wait")))
      expect { pgr_test.wait_minio_cluster }.to hop("create_postgres_resource")
    end
  end

  describe "#create_postgres_resource" do
    it "creates a postgres resource" do
      expect(Prog::Postgres::PostgresResourceNexus).to receive(:assemble).and_return(instance_double(Strand, id: "1234"))
      expect { pgr_test.create_postgres_resource }.to hop("wait_postgres_resource")
    end
  end

  describe "#wait_postgres_resource" do
    it "hops to test_postgres if the postgres resource is ready" do
      expect(pgr_test).to receive(:postgres_resource).exactly(3).and_return(instance_double(PostgresResource, target_server_count: 2, servers: [instance_double(PostgresServer, strand: instance_double(Strand, label: "wait")), instance_double(PostgresServer, strand: instance_double(Strand, label: "wait"))]))
      expect { pgr_test.wait_postgres_resource }.to hop("test_postgres")
    end

    it "naps for 10 seconds if the postgres resource is not ready" do
      expect(pgr_test).to receive(:postgres_resource).exactly(2).and_return(instance_double(PostgresResource, target_server_count: 2, servers: [instance_double(PostgresServer, strand: instance_double(Strand, label: "start"))]))
      expect { pgr_test.wait_postgres_resource }.to nap(10)
    end
  end

  describe "#test_postgres" do
    it "fails if the postgres test fails" do
      expect(pgr_test).to receive(:representative_server).and_return(faulty_representative_server)
      expect { pgr_test.test_postgres }.to hop("destroy_postgres")
    end

    it "hops to trigger_failover if the postgres test passes" do
      expect(pgr_test).to receive(:representative_server).and_return(working_representative_server)
      expect { pgr_test.test_postgres }.to hop("trigger_failover")
    end
  end

  describe "#trigger_failover" do
    it "triggers a failover and hops to wait_failover" do
      expect(pgr_test).to receive(:postgres_resource).at_least(:once).and_return(instance_double(PostgresResource, servers: servers, version: "16"))
      expect(pgr_test).to receive(:update_stack).with({"primary_ubid" => "1234"})
      expect { pgr_test.trigger_failover }.to hop("wait_failover")
    end
  end

  describe "#wait_failover" do
    it "naps for 3 minutes for the 1st time" do
      expect(pgr_test).to receive(:frame).and_return({"failover_wait_started" => false})
      expect { pgr_test.wait_failover }.to nap(180)
    end

    it "hops to test_postgres_after_failover 2nd time" do
      expect(pgr_test).to receive(:frame).and_return({"failover_wait_started" => true})
      expect { pgr_test.wait_failover }.to hop("test_postgres_after_failover")
    end
  end

  describe "#test_postgres_after_failover" do
    it "fails if the postgres test fails" do
      expect(pgr_test).to receive(:representative_server).and_return(faulty_representative_server)
      expect(pgr_test).to receive(:update_stack).with({"fail_message" => "Failed to run read queries after failover"})
      expect { pgr_test.test_postgres_after_failover }.to hop("destroy_postgres")
    end

    it "hops to destroy_postgres if the standby does not exit read-only mode" do
      working_representative_server_1 = instance_double(PostgresServer, run_query: "4159.90\n415.99\n4.1")
      working_representative_server_2 = instance_double(PostgresServer, run_query: "")

      expect(pgr_test).to receive(:representative_server).and_return(working_representative_server_1, working_representative_server_2)
      expect(pgr_test).to receive(:update_stack).with({"fail_message" => "Failed to run write queries after failover"})
      expect { pgr_test.test_postgres_after_failover }.to hop("destroy_postgres")
    end

    it "hops to destroy_postgres if the postgres test succeeds" do
      working_representative_server_1 = instance_double(PostgresServer, run_query: "4159.90\n415.99\n4.1")
      working_representative_server_2 = instance_double(PostgresServer, run_query: "DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1")

      expect(pgr_test).to receive(:representative_server).and_return(working_representative_server_1, working_representative_server_2)
      expect(pgr_test).not_to receive(:update_stack)
      expect { pgr_test.test_postgres_after_failover }.to hop("destroy_postgres")
    end
  end

  describe "#destroy_postgres" do
    it "increments the destroy count and hops to destroy" do
      postgres_resource = instance_double(Prog::Postgres::PostgresResourceNexus, incr_destroy: nil)
      expect(PostgresResource).to receive(:[]).and_return(postgres_resource)
      expect(postgres_resource).to receive(:incr_destroy)

      minio_cluster = instance_double(MinioCluster, incr_destroy: nil)
      expect(MinioCluster).to receive(:[]).and_return(minio_cluster)
      expect(minio_cluster).to receive(:incr_destroy)

      expect(pgr_test).to receive(:frame).exactly(2).and_return({})
      expect { pgr_test.destroy_postgres }.to hop("wait_resources_destroyed")
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps if the postgres resource isn't deleted yet" do
      expect(pgr_test).to receive(:postgres_resource).and_return(instance_double(PostgresResource))
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "hops to destroy if the postgres resource destroyed" do
      expect(pgr_test).to receive(:postgres_resource).and_return(nil)
      expect(pgr_test).to receive(:minio_cluster).and_return(nil)
      expect { pgr_test.wait_resources_destroyed }.to hop("destroy")
    end
  end

  describe "#destroy" do
    it "increments the destroy count and exits if no failure happened" do
      expect(Project).to receive(:[]).exactly(3).and_return(instance_double(Project, id: "1234", destroy: nil))
      expect(pgr_test).to receive(:frame).exactly(3).and_return({"project_created" => false})
      expect { pgr_test.destroy }.to exit({"msg" => "Postgres tests are finished!"})
    end

    it "increments the destroy count and hops to failed if a failure happened" do
      expect(Project).to receive(:[]).exactly(3).and_return(instance_double(Project, id: "1234", destroy: nil))
      expect(pgr_test).to receive(:frame).exactly(3).and_return({"fail_message" => "Test failed", "project_created" => true})
      expect { pgr_test.destroy }.to hop("failed")
    end
  end

  describe "#failed" do
    it "naps" do
      expect { pgr_test.failed }.to nap(15)
    end
  end

  describe ".representative_server" do
    it "returns the representative server" do
      postgres_resource = instance_double(Prog::Postgres::PostgresResourceNexus, representative_server: working_representative_server)
      expect(pgr_test).to receive(:postgres_resource).and_return(postgres_resource)
      expect(pgr_test.representative_server).to eq(working_representative_server)
    end
  end

  describe ".minio_cluster" do
    it "returns the minio cluster" do
      minio_cluster = instance_double(MinioCluster)
      expect(pgr_test).to receive(:frame).and_return({"minio_cluster_id" => "1234"})
      expect(MinioCluster).to receive(:[]).with("1234").and_return(minio_cluster)
      expect(pgr_test.minio_cluster).to eq(minio_cluster)
    end
  end
end
