# frozen_string_literal: true

RSpec.describe ThreadPrinter do
  describe "#print" do
    it "can dump threads" do
      expect(described_class).to receive(:puts).with(/--BEGIN THREAD DUMP, .*/)
      expect(described_class).to receive(:puts).with(/Thread: #<Thread:.*>/)
      expect(described_class).to receive(:puts).with(/backtrace/)
      expect(described_class).to receive(:puts).with(/--END THREAD DUMP, .*/)
      described_class.run
    end

    it "can handle threads with a nil backtrace and/or a created_at" do
      # The documentation calls out that the backtrace is an array or
      # nil.
      expect(described_class).to receive(:puts).with(/--BEGIN THREAD DUMP, .*/)
      expect(described_class).to receive(:puts).with(/Thread: #<InstanceDouble.*>/)
      expect(described_class).to receive(:puts).with(/Created at: .*/)
      expect(described_class).to receive(:puts).with(nil)
      expect(described_class).to receive(:puts).with(/--END THREAD DUMP, .*/)
      th = instance_double(Thread, backtrace: nil)
      expect(th).to receive(:[]).with(:created_at).and_return(Time.now - 30)
      expect(Thread).to receive(:list).and_return([th])
      described_class.run
    end
  end
end
