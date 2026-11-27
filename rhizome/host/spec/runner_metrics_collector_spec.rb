# frozen_string_literal: true

require_relative "../lib/runner_metrics_collector"
require "fileutils"
require "tmpdir"

RSpec.describe RunnerMetricsCollector do
  subject(:collector) { described_class.new(root) }

  let(:root) { Dir.mktmpdir }

  after { FileUtils.rm_rf(root) }

  def write_file(vm_name, file, content)
    FileUtils.mkdir_p("#{root}/#{vm_name}")
    File.write("#{root}/#{vm_name}/#{file}", content)
  end

  describe "#read" do
    it "returns a line per entry in the files of the given VMs" do
      write_file("vmaaaaaa", "2.jsonl", "{\"time\":2}\n")
      write_file("vmaaaaaa", "1.jsonl", "{\"time\":1}\n")
      write_file("vmaaaaaa", "3.jsonl.tmp", "{\"time\":3}\n")
      write_file("vmbbbbbb", "7.jsonl", "{\"time\":7}\n{\"time\":8}\n")
      write_file("vmcccccc", "9.jsonl", "{\"time\":9}\n")

      expect(collector.read(["vmaaaaaa", "vmbbbbbb", "vmdddddd"])).to eq(<<~OUT)
        vmaaaaaa 1.jsonl {"time":1}
        vmaaaaaa 2.jsonl {"time":2}
        vmbbbbbb 7.jsonl {"time":7}
        vmbbbbbb 7.jsonl {"time":8}
      OUT
    end

    it "rejects an invalid VM name" do
      expect { collector.read(["../etc"]) }.to raise_error(RuntimeError, "invalid VM name: \"../etc\"")
    end
  end

  describe "#ack" do
    it "deletes the named files" do
      write_file("vmaaaaaa", "1.jsonl", "{}\n")
      write_file("vmaaaaaa", "2.jsonl", "{}\n")

      collector.ack(["vmaaaaaa 1.jsonl"])
      expect(Dir.children("#{root}/vmaaaaaa")).to eq(["2.jsonl"])
    end

    it "rejects an invalid file name" do
      expect { collector.ack(["vmaaaaaa ../x.jsonl"]) }.to raise_error(RuntimeError, "invalid file name: \"../x.jsonl\"")
    end
  end
end
