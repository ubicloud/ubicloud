# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Repartitioner do
  let(:channel) { :"monitor_#{object_id}_#{rand}" }

  def repartitioner(**)
    described_class.new(partition_number: 1, channel:, max_partition: 8, listen_timeout: 1, recheck_seconds: 18, stale_seconds: 40, **)
  end

  describe ".new" do
    it "repartitions when initializing" do
      expect(Clog).to receive(:emit).with("#{channel} repartitioning").and_call_original
      mp = repartitioner
      expect(mp.repartitioned).to be true
      expect(mp.strand_id_range).to eq("00000000-0000-0000-0000-000000000000".."ffffffff-ffff-ffff-ffff-ffffffffffff")
    end

    it "assumes given partition is last partition" do
      expect(Clog).to receive(:emit).with("#{channel} repartitioning").and_call_original
      expect(repartitioner(partition_number: 2).strand_id_range).to eq("80000000-0000-0000-0000-000000000000".."ffffffff-ffff-ffff-ffff-ffffffffffff")
    end
  end

  describe "#notify" do
    it "uses NOTIFY to notify listeners on given channel" do
      q = Queue.new
      th = Thread.new do
        payload = nil
        DB.listen(channel, after_listen: proc { q.push nil }, timeout: 1) do |_, _, pl|
          payload = pl
        end
        payload
      end
      q.pop(timeout: 1)
      Thread.new { repartitioner(channel:).notify }.join(1)
      expect(th.value).to eq "1"
    end
  end

  describe "#listen" do
    after do
      @mp.shutdown!
      @th.join(1)
      expect(@th.alive?).to be false
    end

    it "repartitions when it receives a notification about a new partition" do
      @mp = mp = repartitioner(listen_timeout: 0.01, recheck_seconds: 2)
      expect(mp.strand_id_range).to eq("00000000-0000-0000-0000-000000000000".."ffffffff-ffff-ffff-ffff-ffffffffffff")
      notify_q = Queue.new
      mp.define_singleton_method(:notify) do
        super()
        notify_q.push true
      end
      @th = Thread.new { mp.listen }

      # Ensure mp is already listening (#listen calls #notify after LISTEN)
      expect(notify_q.pop(timeout: 1)).to be true

      repartition_q = Queue.new
      mp.define_singleton_method(:repartition) do |n|
        super(n)
        repartition_q.push true if n == 2
      end
      Thread.new { repartitioner(partition_number: 2).notify }.join(1)

      expect(repartition_q.pop(timeout: 1)).to be true
      expect(mp.strand_id_range).to eq("00000000-0000-0000-0000-000000000000"..."80000000-0000-0000-0000-000000000000")
    end

    it "repartitions when an existing partition goes stale" do
      @mp = mp = repartitioner(listen_timeout: 0.01, recheck_seconds: 0.03)
      notify_q = Queue.new
      repartition_3q = Queue.new
      repartition_2q = Queue.new
      notified = false
      mp.define_singleton_method(:notify) do
        super()
        unless notified
          notified = true
          notify_q.push true
        end
      end
      mp.define_singleton_method(:repartition) do |n|
        super(n)

        case n
        when 3
          repartition_3q.push true
        when 2
          repartition_2q.push true
        end
      end
      @th = Thread.new { mp.listen }

      expect(notify_q.pop(timeout: 1)).to be true
      expect(mp).to receive(:repartition).with(3).and_call_original
      expect(mp.strand_id_range).to eq("00000000-0000-0000-0000-000000000000".."ffffffff-ffff-ffff-ffff-ffffffffffff")
      t = Thread.new do
        repartitioner(partition_number: 3).notify
        true
      end
      t.join(1)
      expect(t.value).to be true

      expect(repartition_3q.pop(timeout: 1)).to be true
      expect(mp.strand_id_range).to eq("00000000-0000-0000-0000-000000000000"..."55555555-0000-0000-0000-000000000000")
      t = Thread.new do
        repartitioner(partition_number: 2).notify
        true
      end
      t.join(1)
      expect(t.value).to be true

      expect(mp).to receive(:repartition).with(2).and_call_original
      mp.instance_variable_get(:@partition_times)[3] = Time.now - 60
      expect(repartition_2q.pop(timeout: 1)).to be true
      expect(mp.strand_id_range).to eq("00000000-0000-0000-0000-000000000000"..."80000000-0000-0000-0000-000000000000")
    end

    it "emits and otherwise ignores invalid partition numbers" do
      @mp = mp = repartitioner(listen_timeout: 0.01, max_partition: 1)
      q = Queue.new
      listen_q = Queue.new
      expect(mp.strand_id_range).to eq("00000000-0000-0000-0000-000000000000".."ffffffff-ffff-ffff-ffff-ffffffffffff")
      expect(mp).not_to receive(:repartition)
      mp.define_singleton_method(:notify) do
        super()
        listen_q.push true
      end

      @th = Thread.new { mp.listen }
      expect(listen_q.pop(timeout: 1)).to be true
      expect(Clog).to receive(:emit).at_least(:once).and_wrap_original do |m, msg, &blk|
        m.call(msg, &blk)
        if msg == "invalid #{channel} repartition notification"
          q.push true
        end
      end
      th = Thread.new do
        repartitioner(partition_number: 1000).notify
        true
      end
      th.join(1)
      expect(th.value).to be true

      expect(q.pop(timeout: 1)).to be true
      expect(mp.strand_id_range).to eq("00000000-0000-0000-0000-000000000000".."ffffffff-ffff-ffff-ffff-ffffffffffff")
    end

    it "stops listen loop if notification is received after shutting down" do
      @mp = mp = repartitioner
      q = Queue.new
      mp.define_singleton_method(:notify) do
        super()
        q.push nil
      end
      mp.define_singleton_method(:listen) do
        super()
        q.push nil
      end
      @th = Thread.new { mp.listen }

      q.pop(timeout: 1)
      expect(mp.strand_id_range).to eq("00000000-0000-0000-0000-000000000000".."ffffffff-ffff-ffff-ffff-ffffffffffff")
      mp.shutdown!

      expect(mp).not_to receive(:repartition)
      Thread.new { repartitioner(partition_number: 2).notify }.join(1)
      q.pop(timeout: 1)
      expect(mp.strand_id_range).to eq("00000000-0000-0000-0000-000000000000".."ffffffff-ffff-ffff-ffff-ffffffffffff")
    end
  end
end
