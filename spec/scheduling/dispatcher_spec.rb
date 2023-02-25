# frozen_string_literal: true

RSpec.describe Scheduling::Dispatcher do
  subject(:di) { described_class.new }

  describe "#wait_cohort" do
    it "operates when no threads are running" do
      expect { di.wait_cohort }.not_to raise_error
    end

    it "filters for live threads only" do
      di.threads << instance_double(Thread, alive?: true)
      want = di.threads.dup.freeze
      di.threads << instance_double(Thread, alive?: false)

      di.wait_cohort

      expect(di.threads).to eq(want)
    end
  end
end
