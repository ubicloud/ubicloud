# frozen_string_literal: true

RSpec.describe ThreadPrinter do
  describe "#print" do
    it "can dump threads" do
      output = []
      expect(described_class).to receive(:puts) do |str|
        output << str
      end.at_least(:once)

      described_class.run

      expect(output[0]).to match(/--BEGIN THREAD DUMP, .*/)
      expect(output[1]).to match(/Thread: #<Thread:.*>/)
      expect(output[2]).to match(/backtrace/)
      expect(output[-1]).to match(/--END THREAD DUMP, .*/)
    end

    it "can handle threads with a nil backtrace and/or a created_at" do
      # The documentation calls out that the backtrace is an array or
      # nil.
      expect(described_class).to receive(:puts).with(/--BEGIN THREAD DUMP, .*/)
      expect(described_class).to receive(:puts).with(/Thread: #<Thread:.*>/)
      expect(described_class).to receive(:puts).with(/Created at: .*/)
      expect(described_class).to receive(:puts).with(nil)
      expect(described_class).to receive(:puts).with(/--END THREAD DUMP, .*/)
      q = Queue.new
      th = Thread.new { q.pop }
      expect(th).to receive(:backtrace).and_return(nil)
      expect(th).to receive(:[]).with(:created_at).and_return(Time.now - 30)
      expect(Thread).to receive(:list).and_return([th])
      described_class.run
      q.push nil
      th.join(1)
    end
  end
end
