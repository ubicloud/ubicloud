# frozen_string_literal: true

require "digest"
require "fileutils"
require "uri"
require_relative "../../common/lib/arch"

class BootImage
  def initialize(name, version)
    @name = name
    @version = version
  end

  def image_path
    # YYY: Support for unversioned images is still required in StorageVolume
    # code when we want to recreate storage. We can remove this check once we
    # have removed all unversioned images from production.
    @image_path ||= if @version.nil?
      "#{image_root}/#{@name}.raw"
    else
      "#{image_root}/#{@name}-#{@version}.raw"
    end
  end

  def image_root
    "/var/storage/images"
  end

  def download(url:, ca_path: nil, sha256sum: nil)
    return if File.exist?(image_path)

    FileUtils.mkdir_p image_root

    # If image URL has query parameter such as SAS token, File.extname returns
    # it too. We need to remove them and only get extension.
    ext = image_ext(url)
    init_format = initial_format(ext)

    # Use of File::EXCL provokes a crash rather than a race
    # condition if two VMs are lazily getting their images at the
    # same time.
    temp_file_name = @version.nil? ? @name : "#{@name}-#{@version}"
    temp_path = File.join(image_root, "#{temp_file_name}#{ext}.tmp")
    begin
      file_sha256sum = curl_image(url, temp_path, ca_path)
      verify_sha256sum(file_sha256sum, sha256sum)
      convert_image(temp_path, init_format)
    ensure
      rm_if_exists(temp_path)
    end
  end

  def image_ext(url)
    File.extname(URI.parse(url).path)
  end

  def initial_format(ext)
    case ext
    when ".qcow2", ".img"
      "qcow2"
    when ".vhd"
      "vpc"
    when ".raw"
      "raw"
    else
      fail "Unsupported boot_image format: #{ext}"
    end
  end

  def curl_image(url, temp_path, ca_path)
    ca_arg = ca_path ? " --cacert #{ca_path.shellescape}" : ""
    sha256_sum = nil
    File.open(temp_path, File::RDWR | File::CREAT | File::EXCL, 0o644) do
      digest_out = r "bash -c 'curl -f -L10 #{url.shellescape}#{ca_arg} | tee >(openssl dgst -sha256) > #{temp_path.shellescape}'"
      sha256_sum = digest_out.split(" ").last
    end
    sha256_sum
  end

  def verify_sha256sum(file_sha256sum, expected_sha256sum)
    fail "Invalid SHA256 sum." if !expected_sha256sum.nil? && file_sha256sum != expected_sha256sum
  end

  def convert_image(temp_path, initial_format)
    if initial_format == "raw"
      File.rename(temp_path, image_path)
    else
      # Images are presumed to be atomically renamed into the path,
      # i.e. no partial images will be passed to qemu-image.
      r "qemu-img convert -p -f #{initial_format.shellescape} -O raw #{temp_path.shellescape} #{image_path.shellescape}"
    end
  end
end
