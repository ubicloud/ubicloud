# frozen_string_literal: true

# Computes wal-g backup/restore config from a server's vCPU, RAM and Disk count.
# The config maximizes Backup/Restore throughput, applying limits on RAM used.
module WalgConfig
  UPLOAD_QUEUE = 2
  UPLOAD_CONCURRENCY = 4
  S3_MAX_PART_SIZE_UPPER_LIMIT = 64
  DIRECT_IO_BLOCKS_PER_DRIVE = 256

  def self.config_env_contents(vcpu_count:, memory_mib:, direct_io: false, direct_io_drive_count: 4, dense_nvme: false)
    budget_memory_mib = memory_mib * 5 / 100

    # WALG_UPLOAD_DISK_CONCURRENCY is CPU or Disk bound, hence different thresholds
    disk_concurrency =
      if direct_io
        (dense_nvme || vcpu_count <= 2) ? vcpu_count : (vcpu_count / 2)
      else
        (vcpu_count / 2).clamp(1, 128)
      end

    # WALG_S3_MAX_PART_SIZE is memory bound. calculate based on memory budget and concurrency
    peak_parts_in_memory = (disk_concurrency + UPLOAD_QUEUE) * (UPLOAD_CONCURRENCY + 1)
    max_part_size_mib = (budget_memory_mib / peak_parts_in_memory).clamp(5, S3_MAX_PART_SIZE_UPPER_LIMIT)

    # Maximize restore throughput by setting concurrency to vCpu count, 10 is the wal-g default
    # kept as lower bound.
    restore_download_concurrency = vcpu_count.clamp(10, 128)

    lines = [
      "WALG_COMPRESSION_METHOD=lz4",
      "WALG_UPLOAD_DISK_CONCURRENCY=#{disk_concurrency}",
      "WALG_UPLOAD_CONCURRENCY=#{UPLOAD_CONCURRENCY}",
      "WALG_UPLOAD_QUEUE=#{UPLOAD_QUEUE}",
      "WALG_S3_MAX_PART_SIZE=#{max_part_size_mib * 1024 * 1024}",
      "WALG_DOWNLOAD_CONCURRENCY=#{restore_download_concurrency}",
    ]
    if direct_io
      # RAID0 arrays attempt to evenly distribute the data blocks across the block devices.
      # Therefore, larger block reads get fan out to more devices and produce higher throughput.
      direct_io_block_count = direct_io_drive_count * DIRECT_IO_BLOCKS_PER_DRIVE

      lines << "WALG_DIRECT_IO=true"
      lines << "WALG_DIRECT_IO_BLOCK_COUNT=#{direct_io_block_count}"
    end
    lines.join("\n") + "\n"
  end
end
