# frozen_string_literal: true

module WriteTrackingCheck
  METADATA_MAGIC = "BDEV_UBI\0"
  SECTOR_SIZE = 512
  STRIPE_HEADERS_PER_SECTOR = 508
  WRITTEN_FLAG = 0x02

  def self.check(device_config)
    metadata_path = File.join(File.dirname(device_config), "metadata")
    fail "Metadata file not found at #{metadata_path}. This VM was created before write tracking was enabled and cannot be archived." unless File.exist?(metadata_path)

    data = File.binread(metadata_path)
    fail "Metadata file too small" if data.size < SECTOR_SIZE

    magic = data[0, METADATA_MAGIC.bytesize]
    fail "Invalid metadata file (bad magic)" unless magic == METADATA_MAGIC

    stripe_count = data[14, 4].unpack1("V")
    fail "Metadata file reports zero stripes" if stripe_count == 0

    written_count = 0
    stripe_id = 0
    sector = 1
    while stripe_id < stripe_count
      sector_offset = sector * SECTOR_SIZE
      break if sector_offset + SECTOR_SIZE > data.size
      headers_in_sector = [STRIPE_HEADERS_PER_SECTOR, stripe_count - stripe_id].min
      headers_in_sector.times do |i|
        flag = data.getbyte(sector_offset + i)
        written_count += 1 if flag & WRITTEN_FLAG != 0
      end
      stripe_id += headers_in_sector
      sector += 1
    end

    if written_count == 0
      fail "No stripes have write tracking data. This VM was created before write tracking " \
           "was enabled (track_written=true) and cannot be safely archived. " \
           "Archiving would produce a corrupt image."
    end
  end
end
