# frozen_string_literal: true

require_relative "../lib/runner_metrics_entry"

RSpec.describe RunnerMetricsEntry do
  let(:now) { Time.utc(2026, 11, 2, 14, 0, 0) }

  def entry(seq: 1, time: now.to_i - 5, **values)
    metrics = described_class::METRICS.to_h { |metric| [metric, 1.5] }
    {"seq" => seq, "time" => time}.merge(metrics, values.transform_keys(&:to_s))
  end

  def parse(text)
    described_class.parse(+text, "line")
  end

  describe ".parse" do
    it "returns the entry of a JSON object with exactly the expected keys and plausible values" do
      expect(parse(JSON.generate(entry) + "   \n")).to eq(entry)
    end

    it "rejects text that is not valid UTF-8" do
      expect { parse("{\"\xff\"}".b) }.to raise_error(described_class::Invalid, "line is not valid UTF-8")
    end

    it "rejects text longer than a slot" do
      expect { parse(JSON.generate(entry).ljust(4097)) }.to raise_error(described_class::Invalid, "line is longer than 4096 bytes")
    end

    it "rejects text that is not JSON" do
      expect { parse("{\"seq\":") }.to raise_error(described_class::Invalid, /\Aline is not a JSON object: /)
    end

    it "rejects nested values" do
      expect { parse("{\"seq\":[1]}") }.to raise_error(described_class::Invalid, /\Aline is not a JSON object: nesting of 2 is too deep/)
    end

    it "rejects an object without the expected keys in order" do
      expect { parse(JSON.generate(entry.except("time").merge("time" => now.to_i))) }.to raise_error(described_class::Invalid, "line does not have the expected keys")
    end

    it "rejects a seq that is not a positive integer" do
      expect { parse(JSON.generate(entry(seq: 0))) }.to raise_error(described_class::Invalid, "line has seq 0")
    end

    it "rejects a time that is not an integer" do
      expect { parse(JSON.generate(entry(time: 1.5))) }.to raise_error(described_class::Invalid, "line has time 1.5")
    end

    {
      runner_cpu_load_user: [100.5, "100.5"],
      runner_disk_rkb: [-1, "-1"],
      runner_memory_memused: [2**53 + 1, "9007199254740993"],
      runner_queue_ldavg_1: ["1", "\"1\""],
    }.each do |metric, (value, shown)|
      it "rejects #{metric} #{shown}" do
        expect { parse(JSON.generate(entry(metric => value))) }.to raise_error(described_class::Invalid, "line has #{metric} #{shown}")
      end
    end

    it "rejects an infinite value" do
      expect { parse(JSON.generate(entry(runner_disk_wkb: 7.25)).sub("7.25", "1e400")) }.to raise_error(described_class::Invalid, "line has runner_disk_wkb Infinity")
    end
  end

  describe ".check_time" do
    it "rejects a time outside the last hour and a minute ahead" do
      expect { described_class.check_time(entry(time: now.to_i + 61), now) }.to raise_error(described_class::Invalid, "seq 1 has time #{now.to_i + 61}, outside #{now.to_i - 3600}..#{now.to_i + 60}")
    end
  end
end
