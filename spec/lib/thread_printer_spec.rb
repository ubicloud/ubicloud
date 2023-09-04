# frozen_string_literal: true

RSpec.describe ThreadPrinter do
  describe "#print" do
    it "can dump threads" do
      expect(described_class).to receive(:puts).with(/Thread: #<Thread:.*>/)
      expect(described_class).to receive(:puts).with(/backtrace/)
      described_class.run
    end

    it "can handle threads with a nil backtrace" do
      # The documentation calls out that the backtrace is an array or
      # nil.
      expect(described_class).to receive(:puts).with(/Thread: #<InstanceDouble.*>/)
      expect(described_class).to receive(:puts).with(nil)
      expect(Thread).to receive(:list).and_return([instance_double(Thread, backtrace: nil)])
      described_class.run
    end
  end
end
