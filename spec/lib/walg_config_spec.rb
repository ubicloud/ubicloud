# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe WalgConfig do
  # parse the "KEY=value\n" fragment into a hash for assertions
  def env(**) = WalgConfig.config_env_contents(**).lines.map { it.strip.split("=", 2) }.to_h

  describe ".config_env_contents" do
    it "sizes the i8ge.12xlarge (48 vCPU / 384 GiB) row with O_DIRECT (dense NVMe -> vCPU readers)" do
      h = env(vcpu_count: 48, memory_mib: 384 * 1024, direct_io: true, dense_nvme: true)
      expect(h["WALG_COMPRESSION_METHOD"]).to eq("lz4")
      expect(h["WALG_UPLOAD_DISK_CONCURRENCY"]).to eq("48")   # dense NVMe -> full vCPU under O_DIRECT
      expect(h["WALG_UPLOAD_CONCURRENCY"]).to eq("4")
      expect(h["WALG_UPLOAD_QUEUE"]).to eq("2")
      expect(h["WALG_S3_MAX_PART_SIZE"]).to eq((64 * 1024 * 1024).to_s)
      expect(h["WALG_DOWNLOAD_CONCURRENCY"]).to eq("48")      # vCPU, clamped [10,128]
      expect(h["WALG_DIRECT_IO"]).to eq("true")
      expect(h["WALG_DIRECT_IO_BLOCK_COUNT"]).to eq("1024")   # 4 drives * 256
    end

    it "sizes the m8gd.large (2 vCPU / 8 GiB) row: buffered, 5%-RAM cap binds the part size" do
      h = env(vcpu_count: 2, memory_mib: 8 * 1024)
      expect(h["WALG_UPLOAD_DISK_CONCURRENCY"]).to eq("1")    # 1/2 vCPU (buffered) = 2/2 = 1
      expect(h["WALG_UPLOAD_CONCURRENCY"]).to eq("4")
      expect(h["WALG_S3_MAX_PART_SIZE"]).to eq((27 * 1024 * 1024).to_s) # floor(5%*8GiB / ((1+2)*(4+1)))
      expect(h["WALG_DOWNLOAD_CONCURRENCY"]).to eq("10")      # floor
      expect(h).not_to have_key("WALG_DIRECT_IO")             # off by default
    end

    it "keeps peak upload RAM <= 5% of RAM across sizes (the memory cap)" do
      [[2, 8], [16, 128], [48, 384], [192, 1536]].each do |vcpu_count, ram_gib|
        h = env(vcpu_count:, memory_mib: ram_gib * 1024)
        disk = h["WALG_UPLOAD_DISK_CONCURRENCY"].to_i
        upl = h["WALG_UPLOAD_CONCURRENCY"].to_i
        part = h["WALG_S3_MAX_PART_SIZE"].to_i
        peak = (disk + 2) * (upl + 1) * part
        expect(peak).to be <= (ram_gib * 1024**3 / 20)
      end
    end

    it "sets DOWNLOAD_CONCURRENCY = clamp(vCPU, 10, 128) (DR restore, one stream/core)" do
      expect(env(vcpu_count: 2, memory_mib: 16 * 1024)["WALG_DOWNLOAD_CONCURRENCY"]).to eq("10")     # floor
      expect(env(vcpu_count: 24, memory_mib: 192 * 1024)["WALG_DOWNLOAD_CONCURRENCY"]).to eq("24")
      expect(env(vcpu_count: 96, memory_mib: 768 * 1024)["WALG_DOWNLOAD_CONCURRENCY"]).to eq("96")
      expect(env(vcpu_count: 192, memory_mib: 1536 * 1024)["WALG_DOWNLOAD_CONCURRENCY"]).to eq("128") # cap
    end

    it "scales DISK_CONCURRENCY by disk parallelism: 1/2 vCPU generic, vCPU for dense NVMe or <=2 vCPU" do
      # O_DIRECT, generic NVMe, >2 vCPU -> 1/2 vCPU (a single stream saturates the faster device)
      expect(env(vcpu_count: 48, memory_mib: 384 * 1024, direct_io: true)["WALG_UPLOAD_DISK_CONCURRENCY"]).to eq("24")
      # O_DIRECT, dense NVMe -> full vCPU (dense device only saturates with more parallel readers)
      expect(env(vcpu_count: 48, memory_mib: 384 * 1024, direct_io: true, dense_nvme: true)["WALG_UPLOAD_DISK_CONCURRENCY"]).to eq("48")
      # O_DIRECT, generic but <=2 vCPU -> full vCPU (1/2 vCPU would round to 1 and starve reads under load)
      expect(env(vcpu_count: 2, memory_mib: 16 * 1024, direct_io: true)["WALG_UPLOAD_DISK_CONCURRENCY"]).to eq("2")
      # buffered -> 1/2 vCPU regardless of dense flag (cpu.weight, not this count, governs impact)
      buffered = env(vcpu_count: 48, memory_mib: 384 * 1024, direct_io: false, dense_nvme: true)
      expect(buffered["WALG_UPLOAD_DISK_CONCURRENCY"]).to eq("24")
      expect(buffered).not_to have_key("WALG_DIRECT_IO")
      # buffered on 1 vCPU -> clamp floor keeps concurrency >= 1
      expect(env(vcpu_count: 1, memory_mib: 8 * 1024, direct_io: false)["WALG_UPLOAD_DISK_CONCURRENCY"]).to eq("1")
    end

    it "sizes DIRECT_IO_BLOCK_COUNT to the RAID0 drive count (O_DIRECT read spans the stripe)" do
      bc = ->(d) { env(vcpu_count: 48, memory_mib: 384 * 1024, direct_io: true, direct_io_drive_count: d)["WALG_DIRECT_IO_BLOCK_COUNT"] }
      expect(bc.call(1)).to eq("256")    # 1 MiB, single drive
      expect(bc.call(4)).to eq("1024")   # 4 MiB
      expect(bc.call(8)).to eq("2048")   # 8 MiB (caller clamps drive count to 1..8)
    end

    it "emits no rate-limit or bandwidth knobs" do
      h = env(vcpu_count: 48, memory_mib: 384 * 1024, direct_io: true)
      expect(h).not_to have_key("WALG_NETWORK_RATE_LIMIT")
      expect(h).not_to have_key("WALG_DISK_RATE_LIMIT")
    end
  end
end
