# frozen_string_literal: true

RSpec.describe GithubRunnerMetrics do
  let(:now) { Time.utc(2026, 11, 2, 14, 0, 10) }
  let(:labels) { {"ubicloud_resource_id" => "gr1", "vm" => "vm1"} }
  let(:file) { "20261102T140000000000000.jsonl" }

  def entry(statistics)
    JSON.generate({"seq" => 1, "sysstat" => {"hosts" => [{"statistics" => [statistics]}]}})
  end

  def statistics(sections, time: "14:00:05")
    {"timestamp" => {"date" => "2026-11-02", "time" => time, "utc" => 1, "interval" => 5}}.merge(sections)
  end

  def parse(*lines)
    described_class.parse(lines.map { "#{it}\n" }.join, {"vmaaaaaa" => labels}, now:)
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
    it "turns allowlisted sysstat fields into labeled samples and acknowledges each file" do
      stats = statistics({
        "cpu-load" => [{"cpu" => "all", "user" => 6.5, "idle" => 90.0}],
        "queue" => {"ldavg-1" => 0.5, "runq-sz" => 1},
        "memory" => {"memused" => 1024, "memused-percent" => 12.5},
        "network" => {"net-dev" => [{"iface" => "ens3", "rxkB" => 1.5}]},
        "disk" => [{"disk-device" => "vda", "wkB" => 8.0}],
        "filesystems" => [{"mountpoint" => "/", "%fsused" => 10.8}],
        "paging" => {"pgpgin" => 1.0},
      })
      samples, acks = parse("vmaaaaaa #{file}", "vmaaaaaa #{file} #{entry(stats)}")

      expect(samples).to eq(<<~SAMPLES)
        runner_cpu_load_user{ubicloud_resource_id="gr1",vm="vm1",cpu="all"} 6.5 1793628005000
        runner_queue_ldavg_1{ubicloud_resource_id="gr1",vm="vm1"} 0.5 1793628005000
        runner_memory_memused{ubicloud_resource_id="gr1",vm="vm1"} 1024 1793628005000
        runner_filesystems_fsused_percent{ubicloud_resource_id="gr1",vm="vm1",mountpoint="/"} 10.8 1793628005000
        runner_disk_wkb{ubicloud_resource_id="gr1",vm="vm1",device="vda"} 8.0 1793628005000
        runner_net_dev_rxkb{ubicloud_resource_id="gr1",vm="vm1",iface="ens3"} 1.5 1793628005000
      SAMPLES
      expect(acks).to eq(["vmaaaaaa #{file}"])
    end

    it "skips what doesn't fit the sysstat shape or limits" do
      stale = statistics({"queue" => {"ldavg-1" => 1.0}}, time: "12:00:00")
      bad_time = statistics({"queue" => {"ldavg-1" => 1.0}}, time: "25:99")
      bad_items = statistics({
        "cpu-load" => [{"cpu" => "a b", "user" => 1.0}, "x"],
        "disk" => {"disk-device" => "vda", "tps" => 1.0},
        "memory" => {"memused" => "1"},
        "filesystems" => (1..5).map { {"mountpoint" => "/m#{it}", "%fsused" => 1.0} },
      })
      samples, acks = parse(
        "vmbbbbbb #{file}",
        "vmaaaaaa #{file} not json",
        "vmaaaaaa #{file} [1]",
        "vmaaaaaa #{file} #{JSON.generate({"sysstat" => {"hosts" => [{"statistics" => [{"timestamp" => 1}]}]}})}",
        "vmaaaaaa #{file} #{entry(stale)}",
        "vmaaaaaa #{file} #{entry(bad_time)}",
        "vmaaaaaa #{file} #{entry(bad_items)}",
      )

      expect(samples).to eq((1..4).map { "runner_filesystems_fsused_percent{ubicloud_resource_id=\"gr1\",vm=\"vm1\",mountpoint=\"/m#{it}\"} 1.0 1793628005000\n" }.join)
      expect(acks).to eq([])
    end
  end
end
