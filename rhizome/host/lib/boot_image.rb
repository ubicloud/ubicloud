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
    @image_path ||= if @version.nil?
      "#{image_root}/#{@name}.raw"
    else
      "#{image_root}/#{@name}-#{@version}.raw"
    end
  end

  def image_root
    "/var/storage/images"
  end

  def download(url: nil, ca_path: nil, sha256sum: nil)
    return if File.exist?(image_path)

    url ||= get_download_url

    fail "Must provide url for #{@name} image" if url.nil?
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
    curl_image(url, temp_path, ca_path)
    verify_sha256sum(temp_path, sha256sum)
    convert_image(temp_path, init_format)

    rm_if_exists(temp_path)
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
    File.open(temp_path, File::RDWR | File::CREAT | File::EXCL, 0o644) do
      r "curl -f -L10 -o #{temp_path.shellescape} #{url.shellescape}#{ca_arg}"
    end
  end

  def verify_sha256sum(temp_path, sha256sum)
    if !sha256sum.nil? && sha256sum != Digest::SHA256.file(temp_path).hexdigest
      fail "Invalid SHA256 sum."
    end
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

  # YYY: In future all images will have explicit versions and nil won't be
  # allowed, so this method will be removed.
  def version_to_fetch
    @version || case @name
                when "ubuntu-jammy"
                  "20240319"
                when "almalinux-9.3"
                  "20231113"
                end
  end

  def get_download_url
    version = version_to_fetch
    urls = {
      "ubuntu-jammy" => "https://cloud-images.ubuntu.com/releases/jammy/release-#{version}/ubuntu-22.04-server-cloudimg-#{Arch.render(x64: "amd64")}.img",
      "almalinux-9.3" => Arch.render(x64: "x86_64", arm64: "aarch64").yield_self { "https://repo.almalinux.org/almalinux/9/cloud/#{_1}/images/AlmaLinux-9-GenericCloud-9.3-#{version}.#{_1}.qcow2" }
    }
    urls.fetch(@name)
  end
end
