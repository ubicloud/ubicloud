# frozen_string_literal: true

require_relative "../lib/runner_metrics_collector"
require "fileutils"
require "tmpdir"

RSpec.describe RunnerMetricsCollector do
  subject(:collector) { described_class.new(root) }

  let(:root) { Dir.mktmpdir }
  let(:file1) { "20261102T140000000000000.jsonl" }
  let(:file2) { "20261102T140005000000000.jsonl" }

  before do
    # Paths through /proc/self/fd exist only on Linux.
    allow(collector).to receive(:fd_path) { |io| io.path } unless File.directory?("/proc/self/fd")
  end

  after { FileUtils.rm_rf(root) }

  def write_done(vm_name, file, content)
    FileUtils.mkdir_p("#{root}/#{vm_name}/metrics/done")
    File.write("#{root}/#{vm_name}/metrics/done/#{file}", content)
  end

  describe "#read" do
    it "returns each file and its entries for the given VMs" do
      write_done("vmaaaaaa", file2, "{\"seq\":2}\n")
      write_done("vmaaaaaa", file1, "{\"seq\":1}\n")
      write_done("vmaaaaaa", "notes.txt", "x\n")
      write_done("vmbbbbbb", file1, "{\"seq\":7}\n{\"seq\":8}\n")
      write_done("vmcccccc", file1, "{\"seq\":9}\n")

      expect(collector.read(["vmaaaaaa", "vmbbbbbb", "vmdddddd"])).to eq(<<~OUT)
        vmaaaaaa #{file1}
        vmaaaaaa #{file1} {"seq":1}
        vmaaaaaa #{file2}
        vmaaaaaa #{file2} {"seq":2}
        vmbbbbbb #{file1}
        vmbbbbbb #{file1} {"seq":7}
        vmbbbbbb #{file1} {"seq":8}
      OUT
    end

    it "reads up to the byte budget of each VM" do
      stub_const("#{described_class}::MAX_BYTES_PER_VM", 12)
      write_done("vmaaaaaa", file1, "{\"seq\":1}\n{\"seq\":2}\n")
      write_done("vmaaaaaa", file2, "{\"seq\":3}\n")

      expect(collector.read(["vmaaaaaa"])).to eq("vmaaaaaa #{file1}\nvmaaaaaa #{file1} {\"seq\":1}\nvmaaaaaa #{file1} {\"\n")
    end

    it "returns empty files so they can be acknowledged" do
      write_done("vmaaaaaa", file1, "")

      expect(collector.read(["vmaaaaaa"])).to eq("vmaaaaaa #{file1}\n")
    end

    it "reads only regular files with a single link" do
      write_done("vmaaaaaa", "x", "secret\n")
      File.symlink("#{root}/vmaaaaaa/metrics/done/x", "#{root}/vmaaaaaa/metrics/done/#{file1}")
      File.link("#{root}/vmaaaaaa/metrics/done/x", "#{root}/vmaaaaaa/metrics/done/#{file2}")

      expect(collector.read(["vmaaaaaa"])).to eq("")
    end

    it "doesn't follow a symlinked metrics directory" do
      FileUtils.mkdir_p(["#{root}/vmaaaaaa", "#{root}/elsewhere/done"])
      File.write("#{root}/elsewhere/done/#{file1}", "secret\n")
      File.symlink("#{root}/elsewhere", "#{root}/vmaaaaaa/metrics")

      expect(collector.read(["vmaaaaaa"])).to eq("")
    end

    it "skips a metrics path that is not a directory" do
      FileUtils.mkdir_p("#{root}/vmaaaaaa")
      File.write("#{root}/vmaaaaaa/metrics", "")

      expect(collector.read(["vmaaaaaa"])).to eq("")
    end

    it "rejects invalid VM names" do
      expect { collector.read(["../etc"]) }.to raise_error(RuntimeError, 'invalid VM name: "../etc"')
    end
  end

  describe "#ack" do
    it "deletes the given files" do
      write_done("vmaaaaaa", file1, "")
      write_done("vmaaaaaa", file2, "")

      collector.ack(["vmaaaaaa #{file1}", "vmaaaaaa 20261102T140010000000000.jsonl", "vmbbbbbb #{file1}"])

      expect(Dir.children("#{root}/vmaaaaaa/metrics/done")).to eq([file2])
    end

    it "rejects invalid file names" do
      write_done("vmaaaaaa", file1, "")

      expect { collector.ack(["vmaaaaaa ../x"]) }.to raise_error(RuntimeError, 'invalid file name: "../x"')
    end
  end

  describe "#read_file" do
    it "skips files that are gone" do
      expect(collector.read_file("#{root}/missing", 10)).to be_nil
    end
  end
end
