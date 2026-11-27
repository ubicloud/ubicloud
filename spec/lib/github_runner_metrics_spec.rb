# frozen_string_literal: true

RSpec.describe GithubRunnerMetrics do
  def parse(*lines)
    labels_by_vm_name = {"vmaaaaaa" => {"ubicloud_resource_id" => "gr1", "vm" => "vm1"}, "vmbbbbbb" => {"ubicloud_resource_id" => "gr2", "vm" => "vm2"}}
    described_class.parse(lines.map { "#{it}\n" }.join, labels_by_vm_name)
  end

  def install_command(unit)
    <<~COMMAND
      echo #{Base64.strict_encode64(described_class::GUEST_WRITER).shellescape} | base64 -d | sudo tee /usr/local/bin/ubicloud-metrics-writer > /dev/null
      sudo chmod 755 /usr/local/bin/ubicloud-metrics-writer
      echo #{Base64.strict_encode64(unit).shellescape} | base64 -d | sudo tee /etc/systemd/system/ubicloud-metrics-writer.service > /dev/null
      sudo systemctl daemon-reload
      sudo systemctl start ubicloud-metrics-writer.service
    COMMAND
  end

  it "installs the guest writer as a service writing to the metrics disk on metal" do
    expect(described_class.install_command(metal: true)).to eq(install_command(described_class::DISK_UNIT))
  end

  it "installs the guest writer as a service writing to a ring file elsewhere" do
    expect(described_class.install_command(metal: false)).to eq(install_command(described_class::FILE_UNIT))
  end

  describe ".parse" do
    it "turns each entry into samples with its VM's labels, and acks each file once" do
      samples, acks = parse(
        'vmaaaaaa 1.jsonl {"time":1793628005,"runner_queue_ldavg_1":0.5,"runner_memory_memused":1024}',
        'vmaaaaaa 1.jsonl {"time":1793628010,"runner_queue_ldavg_1":0.75,"runner_memory_memused":2048}',
        'vmaaaaaa 2.jsonl {"time":1793628015,"runner_queue_ldavg_1":1.0,"runner_memory_memused":4096}',
        'vmbbbbbb 7.jsonl {"time":1793628005,"runner_queue_ldavg_1":2.0,"runner_memory_memused":8192}',
      )

      expect(samples).to eq(<<~SAMPLES)
        runner_queue_ldavg_1{ubicloud_resource_id="gr1",vm="vm1"} 0.5 1793628005000
        runner_memory_memused{ubicloud_resource_id="gr1",vm="vm1"} 1024 1793628005000
        runner_queue_ldavg_1{ubicloud_resource_id="gr1",vm="vm1"} 0.75 1793628010000
        runner_memory_memused{ubicloud_resource_id="gr1",vm="vm1"} 2048 1793628010000
        runner_queue_ldavg_1{ubicloud_resource_id="gr1",vm="vm1"} 1.0 1793628015000
        runner_memory_memused{ubicloud_resource_id="gr1",vm="vm1"} 4096 1793628015000
        runner_queue_ldavg_1{ubicloud_resource_id="gr2",vm="vm2"} 2.0 1793628005000
        runner_memory_memused{ubicloud_resource_id="gr2",vm="vm2"} 8192 1793628005000
      SAMPLES
      expect(acks).to eq(["vmaaaaaa 1.jsonl", "vmaaaaaa 2.jsonl", "vmbbbbbb 7.jsonl"])
    end

    it "raises for a line that is not JSON" do
      expect { parse("vmaaaaaa 1.jsonl {") }.to raise_error(JSON::ParserError)
    end

    [
      "vmcccccc 1.jsonl {\"time\":1793628005}",
      "vmaaaaaa 1.jsonl",
      "vmaaaaaa 1.jsonl [1793628005]",
      "vmaaaaaa 1.jsonl {\"time\":\"1793628005\"}",
    ].each do |line|
      it "raises for the line #{line}" do
        expect { parse(line) }.to raise_error(described_class::InvalidOutput, "unexpected line: #{line}")
      end
    end
  end

  describe ".parse_ring" do
    let(:now) { Time.utc(2026, 11, 2, 14, 0, 0) }
    let(:labels) { {"ubicloud_resource_id" => "gr1", "vm" => "vm1"} }

    def entry(seq, time: now.to_i - 5)
      {"seq" => seq, "time" => time}.merge(RunnerMetricsEntry::METRICS.to_h { |metric| [metric, seq] })
    end

    def parse_ring(*entries)
      described_class.parse_ring(entries.map { "#{JSON.generate(it)}\n" }.join, labels, after: 3, now:)
    end

    def samples(entry)
      RunnerMetricsEntry::METRICS.map { |metric| "#{metric}{ubicloud_resource_id=\"gr1\",vm=\"vm1\"} #{entry[metric]} #{entry["time"] * 1000}\n" }.join
    end

    it "returns the samples of the lines newer than the given seq, and the newest seq" do
      newer = entry(5)
      new = entry(4, time: now.to_i - 10)

      expect(parse_ring(newer, new)).to eq([samples(newer) + samples(new), 5])
    end

    it "returns the given seq when there are no new lines" do
      expect(parse_ring).to eq(["", 3])
    end

    it "rejects a line that fails the entry checks" do
      expect { parse_ring({"seq" => 4}) }.to raise_error(RunnerMetricsEntry::Invalid, "ring line does not have the expected keys")
    end

    it "rejects a line that is not newer than the given seq" do
      expect { parse_ring(entry(3)) }.to raise_error(RunnerMetricsEntry::Invalid, "ring line has seq 3, not newer than 3")
    end

    it "rejects a line with a time outside the clock window" do
      expect { parse_ring(entry(4, time: now.to_i + 61)) }.to raise_error(RunnerMetricsEntry::Invalid, "seq 4 has time #{now.to_i + 61}, outside #{now.to_i - 3600}..#{now.to_i + 60}")
    end

    it "rejects output larger than the ring" do
      expect { described_class.parse_ring("x" * (1024 * 1024 + 1), labels, after: 3, now:) }.to raise_error(RunnerMetricsEntry::Invalid, "the ring output is 1048577 bytes")
    end
  end
end
