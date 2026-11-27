# frozen_string_literal: true

require_relative "../lib/runner_metrics_agent"
require "tmpdir"

RSpec.describe RunnerMetricsAgent do
  subject(:agent) { described_class.new(File.open(disk_path, "rb"), out_dir) }

  let(:disk_dir) { Dir.mktmpdir }
  let(:disk_path) { "#{disk_dir}/metrics.raw" }
  let(:out_dir) { Dir.mktmpdir }
  let(:now) { Time.utc(2026, 11, 2, 14, 0, 0) }

  after { FileUtils.rm_rf([disk_dir, out_dir]) }

  def entry(seq, time: now.to_i - 5, **values)
    metrics = RunnerMetricsEntry::METRICS.to_h { |metric| [metric, 1.5] }
    {"seq" => seq, "time" => time}.merge(metrics, values.transform_keys(&:to_s))
  end

  def slot(text)
    text.b.ljust(described_class::SLOT_SIZE - 1) + "\n"
  end

  def sample(seq, **values)
    slot(JSON.generate(entry(seq, **values)))
  end

  # A disk of 4 slots; a sample with seq n belongs in slot n % 4.
  def write_disk(slots)
    buffer = described_class::EMPTY_SLOT * 4
    slots.each { |index, slot| buffer[index * described_class::SLOT_SIZE, described_class::SLOT_SIZE] = slot }
    File.binwrite(disk_path, buffer)
  end

  def out_files
    Dir.children(out_dir).sort.to_h { |file| [file, File.read("#{out_dir}/#{file}")] }
  end

  def line(seq, **values)
    JSON.generate(entry(seq, **values).except("seq")) + "\n"
  end

  describe "#entries" do
    it "returns the written slots ordered by seq" do
      write_disk(2 => sample(6), 1 => sample(5))

      expect(agent.entries(File.binread(disk_path))).to eq([[5, entry(5)], [6, entry(6)]])
    end

    it "rejects a disk of another size" do
      write_disk({})

      expect { agent.entries("{}") }.to raise_error(RunnerMetricsEntry::Invalid, "the metrics disk is 2 bytes, not 16384")
    end

    it "rejects a slot that does not end with a newline" do
      write_disk(1 => JSON.generate(entry(1)).ljust(described_class::SLOT_SIZE))

      expect { agent.entries(File.binread(disk_path)) }.to raise_error(RunnerMetricsEntry::Invalid, "slot 1 does not end with a newline")
    end

    it "rejects a slot that fails the entry checks" do
      write_disk(1 => sample(1, runner_cpu_load_user: 100.5))

      expect { agent.entries(File.binread(disk_path)) }.to raise_error(RunnerMetricsEntry::Invalid, "slot 1 has runner_cpu_load_user 100.5")
    end

    it "rejects a slot whose seq does not belong in it" do
      write_disk(1 => sample(2))

      expect { agent.entries(File.binread(disk_path)) }.to raise_error(RunnerMetricsEntry::Invalid, "slot 1 has seq 2")
    end
  end

  describe "#read_entries" do
    it "reads the disk again before failing, as a slot can be read while the guest writes it" do
      write_disk(1 => sample(1).byteslice(0, 100).ljust(described_class::SLOT_SIZE, "\0"))
      expect(agent).to receive(:sleep).with(1) { write_disk(1 => sample(1)) }

      expect(agent.read_entries).to eq([[1, entry(1)]])
    end

    it "fails when the disk is still invalid when read again" do
      write_disk(1 => slot("{"))
      expect(agent).to receive(:sleep).with(1)

      expect { agent.read_entries }.to raise_error(RunnerMetricsEntry::Invalid, /\Aslot 1 is not a JSON object: /)
    end
  end

  describe "#tick" do
    it "writes the samples newer than the last written one into a file named by the newest seq" do
      write_disk(1 => sample(1), 2 => sample(2))
      expect(agent.tick(now)).to eq(2)
      expect(out_files).to eq("2.jsonl" => line(1) + line(2))

      write_disk(1 => sample(1), 2 => sample(2), 3 => sample(3))
      expect(agent.tick(now)).to eq(1)
      expect(agent.tick(now)).to eq(0)
      expect(out_files).to eq("2.jsonl" => line(1) + line(2), "3.jsonl" => line(3))
    end

    it "reuses file names after MAX_FILES files" do
      stub_const("#{described_class}::MAX_FILES", 2)
      (1..3).each do |seq|
        write_disk(seq => sample(seq))
        agent.tick(now)
      end

      expect(out_files).to eq("0.jsonl" => line(2), "1.jsonl" => line(3))
    end

    it "writes nothing for an empty disk" do
      write_disk({})

      expect(agent.tick(now)).to eq(0)
      expect(out_files).to eq({})
    end

    it "fails when the newest seq goes back" do
      write_disk(2 => sample(2))
      agent.tick(now)
      write_disk(1 => sample(1))

      expect { agent.tick(now) }.to raise_error(RunnerMetricsEntry::Invalid, "newest seq went back from 2 to 1")
    end

    it "fails for a new sample with a time outside the clock window" do
      write_disk(1 => sample(1, time: now.to_i + 61))

      expect { agent.tick(now) }.to raise_error(RunnerMetricsEntry::Invalid, "seq 1 has time #{now.to_i + 61}, outside #{now.to_i - 3600}..#{now.to_i + 60}")
    end
  end

  describe "#run" do
    it "writes new samples, then sleeps for the interval, until stopped" do
      write_disk(1 => sample(1, time: Time.now.to_i))
      expect(agent).to receive(:sleep).with(5).and_raise(StopIteration)

      agent.run
      expect(out_files.keys).to eq(["1.jsonl"])
    end
  end
end
