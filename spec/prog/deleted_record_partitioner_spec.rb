# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::DeletedRecordPartitioner do
  subject(:prog) { described_class.new(strand) }

  let(:strand) {
    Strand.create_with_id(UBID.parse("stde1etedrecypart1t10nerzy").to_uuid, prog: "DeletedRecordPartitioner", label: "wait")
  }

  let(:today) { Time.now.utc.to_date }

  let(:models) { described_class::PARTITIONED_MODELS }

  def clear_runway(*models)
    models = described_class::PARTITIONED_MODELS if models.empty?
    models.each do |model|
      model.partition_days.each { model.drop_partition(it) if it > today }
    end
  end

  def fill_runway
    models.each { it.ensure_partitions(through: today + described_class::RUNWAY_DAYS) }
  end

  def runway_page(model)
    Page.from_tag_parts("#{model.name}PartitionRunway")
  end

  describe "#wait" do
    it "starts a cycle under a deadline for coming back" do
      expect { prog.wait }.to hop("check_runway")
      expect(strand.stack.first["deadline_target"]).to eq "wait"
    end

    it "sleeps for a day once a cycle has finished" do
      strand.update(stack: [{"partitions_ensured" => true}])

      expect { prog.wait }.to nap(24 * 60 * 60)
      expect(strand.stack.first).not_to include("partitions_ensured")
    end
  end

  describe "#check_runway" do
    it "pages on a short runway for each partitioned table" do
      clear_runway

      expect { prog.check_runway }.to hop("create_partitions").and change { Page.active.count }.from(0).to(3)
      models.each do |model|
        page = runway_page(model)
        expect(page.summary).to eq "#{model.table_name} has only 0 days of partitions left"
        expect(page.details["runway_days"]).to eq 0
        expect(page.details["wanted_days"]).to eq described_class::RUNWAY_DAYS
      end
    end

    it "pages only for the tables with a short runway" do
      fill_runway
      clear_runway(GithubCompletedWorkflowJob)

      expect { prog.check_runway }.to hop("create_partitions").and change { Page.active.count }.from(0).to(1)
      expect(runway_page(GithubCompletedWorkflowJob).summary).to eq "github_completed_workflow_job has only 0 days of partitions left"
    end

    it "does not page a full runway" do
      fill_runway

      expect { prog.check_runway }.to hop("create_partitions").and not_change { Page.active.count }.from(0)
    end

    it "does not page when no partition exists at all" do
      models.each do |model|
        model.partition_days.each { model.drop_partition(it) }
        expect(model.partition_runway_days).to be_nil
      end

      expect { prog.check_runway }.to hop("create_partitions").and not_change { Page.active.count }.from(0)
    end

    it "does not resolve existing pages, even if the runway has recovered" do
      clear_runway
      expect { prog.check_runway }.to hop("create_partitions")
      page_ids = models.map { runway_page(it).id }
      fill_runway

      expect { prog.check_runway }.to hop("create_partitions")
      expect(Semaphore.where(strand_id: page_ids, name: "resolve").count).to eq 0
    end
  end

  describe "#create_partitions" do
    it "extends the runway of each table to the wanted number of days" do
      clear_runway

      expect(Clog).to receive(:emit).with("created deleted_record partitions", instance_of(Hash)).and_call_original
      expect(Clog).to receive(:emit).with("created github_completed_workflow_run partitions", instance_of(Hash)).and_call_original
      expect(Clog).to receive(:emit).with("created github_completed_workflow_job partitions", instance_of(Hash)).and_call_original
      expect { prog.create_partitions }.to hop("drop_partitions")
      models.each { expect(it.partition_runway_days).to eq described_class::RUNWAY_DAYS }
    end

    it "leaves a full runway alone" do
      fill_runway
      days = models.map(&:partition_days)

      expect(Clog).not_to receive(:emit)
      expect { prog.create_partitions }.to hop("drop_partitions")
      expect(models.map(&:partition_days)).to eq days
    end

    it "resolves the runway pages once the partitions are created" do
      clear_runway
      expect { prog.check_runway }.to hop("create_partitions")
      page_ids = models.map { runway_page(it).id }

      expect { prog.create_partitions }.to hop("drop_partitions")
      expect(Semaphore.where(strand_id: page_ids, name: "resolve").count).to eq 3
    end

    it "resolves runway pages when the runway was already full" do
      clear_runway(GithubCompletedWorkflowRun)
      expect { prog.check_runway }.to hop("create_partitions")
      page_id = runway_page(GithubCompletedWorkflowRun).id
      fill_runway

      expect { prog.create_partitions }.to hop("drop_partitions")
      expect(Semaphore.where(strand_id: page_id, name: "resolve").count).to eq 1
    end
  end

  describe "#drop_partitions" do
    let(:dropped_models) { [GithubCompletedWorkflowRun, GithubCompletedWorkflowJob] }

    it "drops completed github workflow partitions older than the retention period" do
      expect(described_class::RETENTION_DAYS).to eq 44
      expired = today - 45
      retained = today - 44
      dropped_models.each do |model|
        model.create_partition(expired)
        model.create_partition(retained)
      end
      DeletedRecord.create_partition(expired)

      expect(Clog).to receive(:emit).with("dropped github_completed_workflow_run partitions", {github_completed_workflow_run_partitions_dropped: {days: [expired.to_s]}}).and_call_original
      expect(Clog).to receive(:emit).with("dropped github_completed_workflow_job partitions", {github_completed_workflow_job_partitions_dropped: {days: [expired.to_s]}}).and_call_original
      expect { prog.drop_partitions }.to hop("wait")
      dropped_models.each do |model|
        expect(model.partition_days).not_to include(expired)
        expect(model.partition_days).to include(retained, today)
      end
      expect(DeletedRecord.partition_days).to include(expired)
      expect(strand.stack.first["partitions_ensured"]).to be true
    end

    it "does nothing if no partitions have expired" do
      days = models.map(&:partition_days)

      expect(Clog).not_to receive(:emit)
      expect { prog.drop_partitions }.to hop("wait")
      expect(models.map(&:partition_days)).to eq days
      expect(strand.stack.first["partitions_ensured"]).to be true
    end
  end

  it "keeps the pages when creating the partitions fails" do
    clear_runway
    strand.update(label: "check_runway")
    expect(DeletedRecord).to receive(:ensure_partitions) do
      DB.run("INVALID SQL")
    end
    expect { strand.run(10) }.to raise_error(Strand::RunError).and change { Page.active.count }.from(0).to(3)
    expect(strand.reload.label).to eq "create_partitions"
    expect(Semaphore.where(strand_id: Page.active.select_map(:id), name: "resolve").count).to eq 0
  end
end
