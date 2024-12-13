# frozen_string_literal: true

require_relative "../lib/slice_setup"

RSpec.describe SliceSetup do
  subject(:slice_setup) { described_class.new(slice_name) }

  let(:slice_name) { "slice_name.slice" }

  describe "#systemd_service" do
    it "returns the correct systemd service path" do
      expect(slice_setup.systemd_service).to eq("/etc/systemd/system/slice_name.slice")
    end
  end

  describe "#prep" do
    it "installs the systemd unit and starts the systemd unit" do
      cpuset = "3-4"
      expect(slice_setup).to receive(:install_systemd_unit).with(cpuset)
      expect(slice_setup).to receive(:start_systemd_unit)
      slice_setup.prep(cpuset)
    end
  end

  describe "#purge" do
    it "stops the systemd unit and removes the systemd service file" do
      expect(slice_setup).to receive(:r).with("systemctl stop slice_name.slice", expect: [0, 5])
      expect(slice_setup).to receive(:rm_if_exists).with(slice_setup.systemd_service)
      expect(slice_setup).to receive(:r).with("systemctl daemon-reload")
      slice_setup.purge
    end
  end

  describe "#install_systemd_unit" do
    it "writes the slice configuration to the systemd service file" do
      expect(File).to receive(:exist?).with(slice_setup.systemd_service).and_return(false)
      expect(slice_setup).to receive(:safe_write_to_file)
      expect(slice_setup).to receive(:r).with("systemctl daemon-reload")
      slice_setup.install_systemd_unit("3-4")
    end

    it "does nothing if the systemd service file already exists" do
      expect(File).to receive(:exist?).with(slice_setup.systemd_service).and_return(true)
      slice_setup.install_systemd_unit("3-4")
    end

    it "raises an error if the slice name is empty" do
      slice_setup = described_class.new("")
      expect { slice_setup.install_systemd_unit("3-4") }.to raise_error("BUG: unit name must not be empty")
    end

    it "raises an error if the slice name is system.slice" do
      slice_setup = described_class.new("system.slice")
      expect { slice_setup.install_systemd_unit("3-4") }.to raise_error("BUG: we cannot create system units")
    end

    it "raises an error if the slice name is user.slice" do
      slice_setup = described_class.new("user.slice")
      expect { slice_setup.install_systemd_unit("3-4") }.to raise_error("BUG: we cannot create system units")
    end

    it "raises an error if allowed_cpus is nil" do
      expect { slice_setup.install_systemd_unit(nil) }.to raise_error("BUG: allowed_cpus cannot be nil or empty")
    end

    it "raises an error if allowed_cpus is empty" do
      expect { slice_setup.install_systemd_unit("") }.to raise_error("BUG: allowed_cpus cannot be nil or empty")
    end
  end

  describe "#start_systemd_unit" do
    it "starts the systemd unit and writes to the cpuset.cpus.partition file" do
      expect(slice_setup).to receive(:r).with("systemctl start slice_name.slice")
      expect(slice_setup).to receive(:r).with("echo \"root\" > /sys/fs/cgroup/slice_name.slice/cpuset.cpus.partition")
      slice_setup.start_systemd_unit
    end
  end
end
