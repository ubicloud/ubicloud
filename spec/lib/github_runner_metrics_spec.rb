# frozen_string_literal: true

RSpec.describe GithubRunnerMetrics do
  def parse(*lines)
    labels_by_vm_name = {"vmaaaaaa" => {"ubicloud_resource_id" => "gr1", "vm" => "vm1"}, "vmbbbbbb" => {"ubicloud_resource_id" => "gr2", "vm" => "vm2"}}
    described_class.parse(lines.map { "#{it}\n" }.join, labels_by_vm_name)
  end

  it "installs the guest writer as a service" do
    expect(described_class.install_command).to eq(<<~COMMAND)
      echo #{Base64.strict_encode64(described_class::GUEST_WRITER).shellescape} | base64 -d | sudo tee /usr/local/bin/ubicloud-metrics-writer > /dev/null
      sudo chmod 755 /usr/local/bin/ubicloud-metrics-writer
      echo #{Base64.strict_encode64(described_class::DISK_UNIT).shellescape} | base64 -d | sudo tee /etc/systemd/system/ubicloud-metrics-writer.service > /dev/null
      sudo systemctl daemon-reload
      sudo systemctl start ubicloud-metrics-writer.service
    COMMAND
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
end
