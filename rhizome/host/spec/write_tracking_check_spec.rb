# frozen_string_literal: true

require_relative "../lib/write_tracking_check"
require "tmpdir"
require "fileutils"

RSpec.describe WriteTrackingCheck do
  let(:tmpdir) { Dir.mktmpdir }
  let(:device_config) { File.join(tmpdir, "vhost-backend.conf") }
  let(:metadata_path) { File.join(tmpdir, "metadata") }

  after { FileUtils.rm_rf(tmpdir) }

  def build_metadata(stripe_count:, written_stripes: [])
    header = "BDEV_UBI\0".b
    header += "\0" * 5
    header += [stripe_count].pack("V")
    header += "\0" * (WriteTrackingCheck::SECTOR_SIZE - header.size)

    stripes_remaining = stripe_count
    while stripes_remaining > 0
      count = [WriteTrackingCheck::STRIPE_HEADERS_PER_SECTOR, stripes_remaining].min
      sector = "\0".b * WriteTrackingCheck::SECTOR_SIZE
      count.times do |i|
        stripe_id = stripe_count - stripes_remaining + i
        sector.setbyte(i, WriteTrackingCheck::WRITTEN_FLAG) if written_stripes.include?(stripe_id)
      end
      header += sector
      stripes_remaining -= count
    end

    header
  end

  it "fails when metadata file does not exist" do
    expect { described_class.check(device_config) }
      .to raise_error(RuntimeError, /Metadata file not found.*write tracking was enabled/)
  end

  it "fails when metadata file is too small" do
    File.binwrite(metadata_path, "\0" * 100)
    expect { described_class.check(device_config) }
      .to raise_error(RuntimeError, /Metadata file too small/)
  end

  it "fails when metadata has bad magic" do
    File.binwrite(metadata_path, "BADMAGIC\0" + "\0" * (WriteTrackingCheck::SECTOR_SIZE - 9))
    expect { described_class.check(device_config) }
      .to raise_error(RuntimeError, /bad magic/)
  end

  it "fails when stripe count is zero" do
    data = "BDEV_UBI\0".b + "\0" * 5 + [0].pack("V") + "\0" * (WriteTrackingCheck::SECTOR_SIZE - 18)
    File.binwrite(metadata_path, data)
    expect { described_class.check(device_config) }
      .to raise_error(RuntimeError, /zero stripes/)
  end

  it "fails when no stripes have write tracking data" do
    File.binwrite(metadata_path, build_metadata(stripe_count: 10, written_stripes: []))
    expect { described_class.check(device_config) }
      .to raise_error(RuntimeError, /No stripes have write tracking data.*track_written=true.*corrupt image/)
  end

  it "succeeds when stripes have write tracking data" do
    File.binwrite(metadata_path, build_metadata(stripe_count: 10, written_stripes: [0, 3, 7]))
    expect { described_class.check(device_config) }.not_to raise_error
  end

  it "handles large stripe counts spanning multiple sectors" do
    stripe_count = WriteTrackingCheck::STRIPE_HEADERS_PER_SECTOR + 100
    File.binwrite(metadata_path, build_metadata(stripe_count: stripe_count, written_stripes: [WriteTrackingCheck::STRIPE_HEADERS_PER_SECTOR + 50]))
    expect { described_class.check(device_config) }.not_to raise_error
  end
end
