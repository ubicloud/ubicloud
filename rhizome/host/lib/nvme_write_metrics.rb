# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../../common/lib/node_exporter_setup"
require "json"

class NvmeWriteMetrics
  PROM_PATH = File.join(NodeExporterSetup::TEXTFILE_DIR, "nvme_write.prom")
  UNIT_DIR = "/etc/systemd/system"

  # A SMART data unit is 1000 x 512 bytes regardless of the namespace block size.
  DATA_UNIT_BYTES = 512_000

  HOST_WRITTEN = "nvme_host_written_bytes_total"
  NAND_WRITTEN = "nvme_nand_written_bytes_total"

  SERVICE = <<~SERVICE
    [Unit]
    Description=Export NVMe write counters to node_exporter textfile

    [Service]
    Type=oneshot
    ExecStart=/home/rhizome/host/bin/collect-nvme-write-metrics
    TimeoutStartSec=30
  SERVICE

  TIMER = <<~TIMER
    [Unit]
    Description=Schedule NVMe write counter export

    [Timer]
    OnBootSec=60s
    OnUnitActiveSec=60s
    AccuracySec=1s

    [Install]
    WantedBy=timers.target
  TIMER

  Device = Struct.new(:path, :model, :serial)

  def install
    NodeExporterSetup.new.configure
    safe_write_to_file(File.join(UNIT_DIR, "nvme-write-metrics.service"), SERVICE)
    safe_write_to_file(File.join(UNIT_DIR, "nvme-write-metrics.timer"), TIMER)
    r "systemctl daemon-reload"
    r "systemctl enable --now nvme-write-metrics.timer"
  end

  def export
    safe_write_to_file(PROM_PATH, render)
  end

  # Both logs are controller-wide, so a multi-namespace drive is reported once.
  def devices
    JSON.parse(r("nvme list -o json")).fetch("Devices", []).map { |d|
      Device.new(d.fetch("DevicePath"), d.fetch("ModelNumber").strip, d.fetch("SerialNumber").strip)
    }.uniq(&:serial)
  end

  # An unreadable drive drops out of the file; a failed run would leave the
  # previous file in place and its counters looking flat.
  def host_written_bytes(path)
    smart = JSON.parse(r("nvme smart-log -o json :path", path: path))
    Integer(smart.fetch("data_units_written")) * DATA_UNIT_BYTES
  rescue CommandFail => e
    warn "#{path}: smart-log unreadable: #{e.stderr.strip}"
    nil
  end

  # OCP SMART extension log (C0h); nil on drives without it.
  def nand_written_bytes(path)
    log = JSON.parse(r("nvme ocp smart-add-log -o json :path", path: path))
    units = log.fetch("Physical media units written")
    (Integer(units.fetch("hi")) << 64) + Integer(units.fetch("lo"))
  rescue CommandFail, KeyError
    nil
  end

  def render
    host_lines = []
    nand_lines = []
    devices.each do |dev|
      next unless (host = host_written_bytes(dev.path))

      labels = format_labels(dev)
      host_lines << "#{HOST_WRITTEN}{#{labels}} #{host}"
      if (nand = nand_written_bytes(dev.path))
        nand_lines << "#{NAND_WRITTEN}{#{labels}} #{nand}"
      end
    end

    [
      "# HELP #{HOST_WRITTEN} Bytes the host has written to the drive over its lifetime (SMART Data Units Written).",
      "# TYPE #{HOST_WRITTEN} counter",
      *host_lines,
      "# HELP #{NAND_WRITTEN} Bytes the drive has written to its flash over its lifetime (OCP Physical Media Units Written).",
      "# TYPE #{NAND_WRITTEN} counter",
      *nand_lines,
    ].join("\n") + "\n"
  end

  LABEL_ESCAPES = {"\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n"}.freeze

  def format_labels(dev)
    {device: File.basename(dev.path), model: dev.model, serial: dev.serial}
      .map { |k, v| "#{k}=\"#{v.gsub(/[\\"\n]/, LABEL_ESCAPES)}\"" }
      .join(",")
  end
end
