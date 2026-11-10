# frozen_string_literal: true

require_relative "../lib/nvme_write_metrics"

RSpec.describe NvmeWriteMetrics do
  subject(:nwm) { described_class.new }

  let(:nvme_list) do
    <<~JSON
      {
        "Devices":[
          {
            "NameSpace":1,
            "DevicePath":"/dev/nvme1n1",
            "GenericPath":"/dev/ng1n1",
            "Firmware":"GDC5902Q",
            "ModelNumber":"SAMSUNG MZQL21T9HCJR-00A07",
            "SerialNumber":"S64GNN0WC00475",
            "UsedBytes":1772833013760,
            "MaximumLBA":468843606,
            "PhysicalSize":1920383410176,
            "SectorSize":4096
          },
          {
            "NameSpace":1,
            "DevicePath":"/dev/nvme0n1",
            "GenericPath":"/dev/ng0n1",
            "Firmware":"GDC5902Q",
            "ModelNumber":"SAMSUNG MZQL21T9HCJR-00A07 ",
            "SerialNumber":"S64GNN0WC00472 ",
            "UsedBytes":1889320935424,
            "MaximumLBA":3750748848,
            "PhysicalSize":1920383410176,
            "SectorSize":512
          },
          {
            "NameSpace":2,
            "DevicePath":"/dev/nvme0n2",
            "ModelNumber":"SAMSUNG MZQL21T9HCJR-00A07",
            "SerialNumber":"S64GNN0WC00472"
          }
        ]
      }
    JSON
  end

  let(:smart_log) do
    <<~JSON
      {
        "critical_warning":0,
        "avail_spare":100,
        "spare_thresh":10,
        "percent_used":2,
        "data_units_read":398233366,
        "data_units_written":550832190,
        "host_write_commands":24557505399
      }
    JSON
  end

  # hi is 0 on real drives; set to 1 here to exercise the 128-bit combination.
  let(:ocp_log) do
    <<~JSON
      {
        "Physical media units written":{
          "hi":1,
          "lo":310568409014272
        },
        "Physical media units read":{
          "hi":0,
          "lo":190940593958912
        },
        "Percent free blocks":14
      }
    JSON
  end

  describe "#devices" do
    it "lists each drive once by serial, with trimmed model and serial" do
      expect(nwm).to receive(:_run_command).with("nvme list -o json").and_return(nvme_list)

      expect(nwm.devices).to eq [
        described_class::Device.new("/dev/nvme1n1", "SAMSUNG MZQL21T9HCJR-00A07", "S64GNN0WC00475"),
        described_class::Device.new("/dev/nvme0n1", "SAMSUNG MZQL21T9HCJR-00A07", "S64GNN0WC00472"),
      ]
    end

    it "is empty on a host without NVMe drives" do
      expect(nwm).to receive(:_run_command).with("nvme list -o json").and_return("{\n}\n")

      expect(nwm.devices).to eq []
    end
  end

  describe "#host_written_bytes" do
    it "converts SMART data units to bytes" do
      expect(nwm).to receive(:_run_command).with("nvme smart-log -o json /dev/nvme1n1").and_return(smart_log)

      expect(nwm.host_written_bytes("/dev/nvme1n1")).to eq 550832190 * 512_000
    end

    it "is nil for a drive whose SMART log cannot be read and says why" do
      expect(nwm).to receive(:_run_command).with("nvme smart-log -o json /dev/nvme1n1").and_raise(CommandFail.new("command failed", "", "No such device\n"))

      expect { expect(nwm.host_written_bytes("/dev/nvme1n1")).to be_nil }.to output("/dev/nvme1n1: smart-log unreadable: No such device\n").to_stderr
    end
  end

  describe "#nand_written_bytes" do
    it "combines the 128-bit OCP physical media units written counter" do
      expect(nwm).to receive(:_run_command).with("nvme ocp smart-add-log -o json /dev/nvme1n1").and_return(ocp_log)

      expect(nwm.nand_written_bytes("/dev/nvme1n1")).to eq((1 << 64) + 310568409014272)
    end

    it "is nil for a drive without the OCP log" do
      expect(nwm).to receive(:_run_command).with("nvme ocp smart-add-log -o json /dev/nvme1n1").and_raise(CommandFail.new("command failed", "", "NVMe status: Invalid Log Page"))

      expect(nwm.nand_written_bytes("/dev/nvme1n1")).to be_nil
    end

    it "is nil when the OCP log lacks the counter" do
      expect(nwm).to receive(:_run_command).with("nvme ocp smart-add-log -o json /dev/nvme1n1").and_return('{"Bad user thermal temperature time":0}')

      expect(nwm.nand_written_bytes("/dev/nvme1n1")).to be_nil
    end
  end

  describe "#render" do
    it "emits both counters per drive, omits the NAND series where unavailable, and skips an unreadable drive" do
      expect(nwm).to receive(:_run_command).with("nvme list -o json").and_return(nvme_list.sub('"SerialNumber":"S64GNN0WC00472"', '"SerialNumber":"S64GNN0WC00473"'))
      expect(nwm).to receive(:_run_command).with("nvme smart-log -o json /dev/nvme0n2").and_raise(CommandFail.new("command failed", "", "No such device"))
      expect(nwm).to receive(:warn).with("/dev/nvme0n2: smart-log unreadable: No such device")
      expect(nwm).to receive(:_run_command).with("nvme smart-log -o json /dev/nvme1n1").and_return(smart_log)
      expect(nwm).to receive(:_run_command).with("nvme ocp smart-add-log -o json /dev/nvme1n1").and_return(ocp_log)
      expect(nwm).to receive(:_run_command).with("nvme smart-log -o json /dev/nvme0n1").and_return("{\"data_units_written\":869574372}")
      expect(nwm).to receive(:_run_command).with("nvme ocp smart-add-log -o json /dev/nvme0n1").and_raise(CommandFail.new("command failed", "", ""))

      expect(nwm.render).to eq <<~PROM
        # HELP nvme_host_written_bytes_total Bytes the host has written to the drive over its lifetime (SMART Data Units Written).
        # TYPE nvme_host_written_bytes_total counter
        nvme_host_written_bytes_total{device="nvme1n1",model="SAMSUNG MZQL21T9HCJR-00A07",serial="S64GNN0WC00475"} 282026081280000
        nvme_host_written_bytes_total{device="nvme0n1",model="SAMSUNG MZQL21T9HCJR-00A07",serial="S64GNN0WC00472"} 445222078464000
        # HELP nvme_nand_written_bytes_total Bytes the drive has written to its flash over its lifetime (OCP Physical Media Units Written).
        # TYPE nvme_nand_written_bytes_total counter
        nvme_nand_written_bytes_total{device="nvme1n1",model="SAMSUNG MZQL21T9HCJR-00A07",serial="S64GNN0WC00475"} 18447054642118565888
      PROM
    end
  end

  describe "#format_labels" do
    it "escapes backslashes, quotes and newlines in label values" do
      dev = described_class::Device.new("/dev/nvme0n1", "Mo\"del\\X\nY", "SN1")

      expect(nwm.format_labels(dev)).to eq "device=\"nvme0n1\",model=\"Mo\\\"del\\\\X\\nY\",serial=\"SN1\""
    end
  end

  describe "#export" do
    it "writes the rendered metrics to the node_exporter textfile directory" do
      expect(nwm).to receive(:render).and_return("rendered\n")
      expect(nwm).to receive(:safe_write_to_file).with("/var/lib/node_exporter/nvme_write.prom", "rendered\n")

      nwm.export
    end
  end

  describe "#install" do
    it "configures node_exporter, writes the units and enables the timer" do
      calls = []
      node_exporter = instance_double(NodeExporterSetup)
      expect(NodeExporterSetup).to receive(:new).and_return(node_exporter)
      expect(node_exporter).to receive(:configure) { calls << :configure }
      expect(nwm).to receive(:safe_write_to_file).with("/etc/systemd/system/nvme-write-metrics.service", described_class::SERVICE) { calls << :service }
      expect(nwm).to receive(:safe_write_to_file).with("/etc/systemd/system/nvme-write-metrics.timer", described_class::TIMER) { calls << :timer }
      expect(nwm).to receive(:_run_command).with("systemctl daemon-reload") { calls << :reload }
      expect(nwm).to receive(:_run_command).with("systemctl enable --now nvme-write-metrics.timer") { calls << :enable }

      nwm.install
      expect(calls).to eq [:configure, :service, :timer, :reload, :enable]
    end
  end
end
