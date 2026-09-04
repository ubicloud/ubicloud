# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::PostgresImageFamily do
  subject(:pgr_test) { described_class.new(pgr_strand) }

  let(:pgr_strand) { described_class.assemble }

  let(:test_project) { Project.create(name: "test-project") }
  let(:service_project) { Project.create(name: "service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:timeline) { create_postgres_timeline(location_id:) }

  let(:postgres_resource) { create_postgres_resource(project: test_project, location_id:) }

  def setup_postgres_resource
    postgres_resource
    postgres_resource.strand.update(label: "wait")
    create_postgres_server(resource: postgres_resource, timeline:).strand.update(label: "wait")
    refresh_frame(pgr_test, new_values: {"postgres_resource_id" => postgres_resource.id})
  end

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
  end

  describe ".assemble" do
    it "defaults the migration from ubuntu-2204 to ubuntu-2604" do
      expect(pgr_strand.stack.first["from_image_family"]).to eq("ubuntu-2204")
      expect(pgr_strand.stack.first["to_image_family"]).to eq("ubuntu-2604")
    end

    it "threads explicit families into the frame" do
      st = described_class.assemble(from_image_family: "ubuntu-2404", to_image_family: "ubuntu-2604")
      expect(st.stack.first["from_image_family"]).to eq("ubuntu-2404")
      expect(st.stack.first["to_image_family"]).to eq("ubuntu-2604")
    end
  end

  describe "#start" do
    it "creates a resource on metal with the source image family and hops to wait_postgres_resource" do
      expect { pgr_test.start }.to hop("wait_postgres_resource")
      pr = PostgresResource[pgr_test.strand.stack.first["postgres_resource_id"]]
      expect(pr.target_image_family).to eq("ubuntu-2204")
      expect(pr.name).to eq("postgres-test-image-family")
    end
  end

  describe "#wait_postgres_resource" do
    before { setup_postgres_resource }

    let(:sshable) { pgr_test.representative_server.vm.sshable }

    it "hops to verify_initial_image_family if the postgres resource is ready" do
      expect(sshable).to receive(:_cmd).and_return("1\n")
      expect { pgr_test.wait_postgres_resource }.to hop("verify_initial_image_family")
    end

    it "naps for 10 seconds if the postgres resource is not ready" do
      expect(sshable).to receive(:_cmd).and_return("\n")
      expect { pgr_test.wait_postgres_resource }.to nap(10)
    end
  end

  describe "#verify_initial_image_family" do
    before { setup_postgres_resource }

    it "hops to populate_data when the representative server runs the source family" do
      pgr_test.representative_server.update(image_family: "ubuntu-2204")
      expect { pgr_test.verify_initial_image_family }.to hop("populate_data")
      expect(pgr_test.strand.stack.first["fail_message"]).to be_nil
    end

    it "records a failure and hops to destroy when the family does not match" do
      pgr_test.representative_server.update(image_family: "ubuntu-2604")
      expect { pgr_test.verify_initial_image_family }.to hop("destroy")
      expect(pgr_test.strand.stack.first["fail_message"]).to eq('Representative server runs image family "ubuntu-2604", expected "ubuntu-2204"')
    end
  end

  describe "#populate_data" do
    before { setup_postgres_resource }

    let(:sshable) { pgr_test.representative_server.vm.sshable }

    it "records a failure if the test queries do not match" do
      expect(sshable).to receive(:_cmd).and_return("\n")
      expect { pgr_test.populate_data }.to hop("destroy")
      expect(pgr_test.strand.stack.first["fail_message"]).to eq("Failed to run test queries before migration")
    end

    it "hops to trigger_migration if the test queries match" do
      expect(sshable).to receive(:_cmd).and_return("DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1\n")
      expect { pgr_test.populate_data }.to hop("trigger_migration")
      expect(pgr_test.strand.stack.first["fail_message"]).to be_nil
    end
  end

  describe "#trigger_migration" do
    before { setup_postgres_resource }

    it "records the pre-migration timeline, sets the target family, and hops to wait_migration" do
      expect { pgr_test.trigger_migration }.to hop("wait_migration")
      expect(pgr_test.strand.stack.first["pre_migration_timeline_id"]).to eq(timeline.id)
      expect(postgres_resource.reload.target_image_family).to eq("ubuntu-2604")
    end
  end

  describe "#wait_migration" do
    before { setup_postgres_resource }

    let(:sshable) { pgr_test.representative_server.vm.sshable }

    it "hops to verify_migrated_image_family once the fleet is converged on the target family" do
      postgres_resource.update(target_image_family: "ubuntu-2604")
      pgr_test.representative_server.update(image_family: "ubuntu-2604")
      expect(sshable).to receive(:_cmd).and_return("1\n")
      expect { pgr_test.wait_migration }.to hop("verify_migrated_image_family")
    end

    it "naps while the servers still need recycling onto the target family" do
      postgres_resource.update(target_image_family: "ubuntu-2604")
      expect { pgr_test.wait_migration }.to nap(10)
    end
  end

  describe "#verify_migrated_image_family" do
    before { setup_postgres_resource }

    it "hops to verify_data_survived when the representative server runs the target family" do
      pgr_test.representative_server.update(image_family: "ubuntu-2604")
      expect { pgr_test.verify_migrated_image_family }.to hop("verify_data_survived")
      expect(pgr_test.strand.stack.first["fail_message"]).to be_nil
    end

    it "records a failure and hops to destroy when the family did not migrate" do
      pgr_test.representative_server.update(image_family: "ubuntu-2204")
      expect { pgr_test.verify_migrated_image_family }.to hop("destroy")
      expect(pgr_test.strand.stack.first["fail_message"]).to eq('Representative server runs image family "ubuntu-2204", expected "ubuntu-2604"')
    end
  end

  describe "#verify_data_survived" do
    before { setup_postgres_resource }

    let(:sshable) { pgr_test.representative_server.vm.sshable }

    it "records a failure and hops to destroy if the data did not survive" do
      expect(sshable).to receive(:_cmd).and_return("\n")
      expect { pgr_test.verify_data_survived }.to hop("destroy")
      expect(pgr_test.strand.stack.first["fail_message"]).to eq("Data did not survive the image family migration")
    end

    it "hops to test_postgres if the pre-migration data is still present" do
      expect(sshable).to receive(:_cmd).and_return("4159.90\n415.99\n4.1\n")
      expect { pgr_test.verify_data_survived }.to hop("test_postgres")
      expect(pgr_test.strand.stack.first["fail_message"]).to be_nil
    end
  end

  describe "#test_postgres" do
    before { setup_postgres_resource }

    let(:sshable) { pgr_test.representative_server.vm.sshable }

    it "records a failure if the test queries do not match" do
      expect(sshable).to receive(:_cmd).and_return("\n")
      expect { pgr_test.test_postgres }.to hop("destroy")
      expect(pgr_test.strand.stack.first["fail_message"]).to eq("Failed to run test queries after migration")
    end

    it "hops to destroy without a failure if the test queries match" do
      expect(sshable).to receive(:_cmd).and_return("DROP TABLE\nCREATE TABLE\nINSERT 0 10\n4159.90\n415.99\n4.1\n")
      expect { pgr_test.test_postgres }.to hop("destroy")
      expect(pgr_test.strand.stack.first["fail_message"]).to be_nil
    end
  end

  describe "#destroy_postgres" do
    it "collects the pre-migration and current timelines, destroys the resource, and hops" do
      setup_postgres_resource
      new_timeline = create_postgres_timeline(location_id:)
      refresh_frame(pgr_test, new_values: {"pre_migration_timeline_id" => new_timeline.id})

      expect { pgr_test.destroy_postgres }.to hop("wait_resources_destroyed")
      expect(pgr_test.strand.stack.first["timeline_ids"]).to contain_exactly(timeline.id, new_timeline.id)
      expect(Semaphore.where(strand_id: postgres_resource.id, name: "destroy").count).to eq(1)
    end
  end

  describe "#wait_resources_destroyed" do
    it "naps while the postgres resource is not deleted yet" do
      setup_postgres_resource
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
    end

    it "destroys retained timelines and naps" do
      refresh_frame(pgr_test, new_values: {"timeline_ids" => [timeline.id]})
      expect { pgr_test.wait_resources_destroyed }.to nap(5)
      expect(Semaphore.where(strand_id: timeline.id, name: "destroy").count).to eq(1)
    end

    it "hops to finish once the resources are gone" do
      expect { pgr_test.wait_resources_destroyed }.to hop("finish")
    end
  end
end
