# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::DeletedRecordPartitioner do
  subject(:prog) { described_class.new(strand) }

  let(:strand) {
    Strand.create_with_id(UBID.parse("stde1etedrecypart1t10nerzy").to_uuid, prog: "DeletedRecordPartitioner", label: "wait")
  }

  let(:today) { Time.now.utc.to_date }

  def clear_runway
    DeletedRecord.partition_days.each { DeletedRecord.drop_partition(it) if it > today }
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
    it "pages on a short runway" do
      clear_runway

      expect { prog.check_runway }.to hop("create_partitions").and change { Page.active.count }.from(0).to(1)
      page = Page.first
      expect(page.summary).to eq "deleted_record has only 0 days of partitions left"
      expect(page.details["runway_days"]).to eq 0
      expect(page.details["wanted_days"]).to eq DeletedRecord::RUNWAY_DAYS
    end

    it "does not page a full runway" do
      DeletedRecord.ensure_partitions(through: today + DeletedRecord::RUNWAY_DAYS)

      expect { prog.check_runway }.to hop("create_partitions").and not_change { Page.active.count }.from(0)
    end

    it "does not page when no partition exists at all" do
      DeletedRecord.partition_days.each { DeletedRecord.drop_partition(it) }
      expect(DeletedRecord.partition_runway_days).to be_nil

      expect { prog.check_runway }.to hop("create_partitions").and not_change { Page.active.count }.from(0)
    end

    it "resolves the page once the runway recovers" do
      clear_runway
      expect { prog.check_runway }.to hop("create_partitions")
      page = Page.first
      DeletedRecord.ensure_partitions(through: today + DeletedRecord::RUNWAY_DAYS)

      expect { prog.check_runway }.to hop("create_partitions")
      expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq 1
    end
  end

  describe "#create_partitions" do
    it "extends the runway to the wanted number of days" do
      clear_runway

      expect { prog.create_partitions }.to hop("wait")
      expect(DeletedRecord.partition_runway_days).to eq DeletedRecord::RUNWAY_DAYS
      expect(strand.stack.first["partitions_ensured"]).to be true
    end

    it "leaves a full runway alone" do
      DeletedRecord.ensure_partitions(through: today + DeletedRecord::RUNWAY_DAYS)
      days = DeletedRecord.partition_days

      expect { prog.create_partitions }.to hop("wait")
      expect(DeletedRecord.partition_days).to eq days
    end
  end

  it "keeps the page when creating the partitions fails" do
    clear_runway
    strand.update(label: "check_runway")
    expect(DeletedRecord).to receive(:ensure_partitions) do
      DB.run("INVALID SQL")
    end
    expect { strand.run(10) }.to raise_error(Strand::RunError).and change { Page.active.count }.from(0).to(1)
    expect(strand.reload.label).to eq "create_partitions"
  end
end
