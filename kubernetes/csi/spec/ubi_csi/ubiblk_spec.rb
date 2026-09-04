# frozen_string_literal: true

require "logger"
require "tmpdir"
require "spec_helper"

RSpec.describe Csi::Ubiblk do
  let(:logger) { Logger.new(File::NULL) }
  let(:ubiblk) { described_class.new(logger:) }
  let(:success_status) { instance_double(Process::Status, success?: true) }
  let(:failure_status) { instance_double(Process::Status, success?: false) }

  describe "#setup" do
    it "stages the binaries and loads the kernel module" do
      expect(ubiblk).to receive(:stage_binaries)
      expect(ubiblk).to receive(:load_kernel_module)

      ubiblk.setup
    end
  end

  describe "#stage_binaries" do
    it "copies every binary to the node as an executable" do
      Dir.mktmpdir do |dir|
        image_dir = File.join(dir, "image")
        host_dir = File.join(dir, "host")
        FileUtils.mkdir_p(image_dir)
        described_class::BINARIES.each { |name| File.write(File.join(image_dir, name), "#{name} contents") }
        stub_const("Csi::Ubiblk::IMAGE_DIR", image_dir)
        stub_const("Csi::Ubiblk::HOST_DIR", host_dir)

        ubiblk.stage_binaries

        described_class::BINARIES.each do |name|
          path = File.join(host_dir, name)
          expect(File.read(path)).to eq("#{name} contents")
          expect(File.stat(path).mode & 0o777).to eq(0o755)
        end
      end
    end

    it "leaves an already staged binary alone" do
      Dir.mktmpdir do |dir|
        image_dir = File.join(dir, "image")
        host_dir = File.join(dir, "host")
        FileUtils.mkdir_p(image_dir)
        FileUtils.mkdir_p(host_dir)
        described_class::BINARIES.each { |name| File.write(File.join(image_dir, name), "new contents") }
        staged_path = File.join(host_dir, "ublk-backend")
        File.write(staged_path, "staged contents")
        File.chmod(0o755, staged_path)
        stub_const("Csi::Ubiblk::IMAGE_DIR", image_dir)
        stub_const("Csi::Ubiblk::HOST_DIR", host_dir)

        ubiblk.stage_binaries

        expect(File.read(staged_path)).to eq("staged contents")
      end
    end
  end

  describe "#load_kernel_module" do
    it "loads ublk_drv in the host namespaces" do
      expect(ubiblk).to receive(:run_cmd).with(
        "nsenter", "-t", "1", "-a", "modprobe", "ublk_drv", req_id: "ubiblk-setup",
      ).and_return(["", success_status])

      ubiblk.load_kernel_module
    end

    it "raises when modprobe fails" do
      expect(ubiblk).to receive(:run_cmd).and_return(["module not found", failure_status])

      expect { ubiblk.load_kernel_module }.to raise_error(RuntimeError, "Failed to load the ublk_drv kernel module: module not found")
    end
  end
end
