# frozen_string_literal: true

require "fileutils"
require "uri"
require_relative "../../common/lib/arch"
require_relative "../../common/lib/util"

class BootImage
  def initialize(name, version, image_root: "/var/storage/images")
    @name = name
    @version = version
    @image_root = image_root
  end

  def image_path
    # YYY: Support for unversioned images is still required in StorageVolume
    # code when we want to recreate storage. We can remove this check once we
    # have removed all unversioned images from production.
    @image_path ||= if @version.nil?
      "#{@image_root}/#{@name}.raw"
    else
      "#{@image_root}/#{@name}-#{@version}.raw"
    end
  end

  def download(url:, ca_path: nil, sha256sum: nil, use_htcat: false)
    return if File.exist?(image_path)

    FileUtils.mkdir_p @image_root

    # If image URL has query parameter such as SAS token, File.extname returns
    # it too. We need to remove them and only get extension.
    ext = image_ext(url)
    init_format = initial_format(ext)

    # Use of File::EXCL provokes a crash rather than a race
    # condition if two VMs are lazily getting their images at the
    # same time.
    temp_file_name = @version.nil? ? @name : "#{@name}-#{@version}"
    temp_path = File.join(@image_root, "#{temp_file_name}#{ext}.tmp")
    begin
      file_sha256sum = if use_htcat
        htcat_image(url, temp_path)
      else
        curl_image(url, temp_path, ca_path)
      end
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
    sha256_sum = nil
    File.open(temp_path, File::RDWR | File::CREAT | File::EXCL, 0o644) do
      # Spelled long because curl bundles short options: "-L10" was --location
      # --tlsv1 --http1.0 (curl's own table: "-1, --tlsv1", "-0, --http1.0"),
      # not a redirect limit. --tlsv1 lowers the accepted floor to TLS 1.0 and
      # --http1.0 forces HTTP/1.0 on a multi-gigabyte image fetch, which is the
      # opposite of what this path wants; both are dropped. --max-redirs is
      # deliberately not substituted for the digit: no limit was ever set here,
      # and curl's default of 50 is what this download has followed.
      #
      # pipefail, so curl's failure is the pipeline's failure. Without it the
      # pipeline exits with tee's status, curl can die mid-stream, and the only
      # thing that notices is the digest gate -- which then blames the bytes
      # rather than the transfer that stopped early.
      inner = if ca_path
        cmd("set -o pipefail; curl --fail --location :url --cacert :ca_path | tee >(openssl dgst -sha256) > :temp_path", url: url, ca_path: ca_path, temp_path: temp_path)
      else
        cmd("set -o pipefail; curl --fail --location :url | tee >(openssl dgst -sha256) > :temp_path", url: url, temp_path: temp_path)
      end
      digest_out = r "bash -c :inner", inner: inner
      sha256_sum = digest_out.split(" ").last
    end
    sha256_sum
  end

  def htcat_image(url, temp_path)
    File.open(temp_path, File::RDWR | File::CREAT | File::EXCL, 0o644) do
      run_htcat(url, temp_path)
      sha256_file(temp_path)
    end
  end

  # No pipe. Piping htcat into tee makes the shell report tee's exit status, so
  # htcat can fail or lose a fragment invisibly and the truncation arrives
  # minutes later as "Invalid SHA256 sum." with no cause attached. A plain
  # redirect makes htcat's exit status the command's own, and CommandFail
  # carries htcat's stderr to the caller.
  def run_htcat(url, temp_path)
    inner = cmd("htcat -parallelism=12 -max-fragment-size=32 :url > :temp_path", url: url, temp_path: temp_path)
    r "bash -c :inner", inner: inner
  end

  # Taken from the finished file rather than from the stream, so the digest
  # describes what was written and not what passed through the pipe.
  def sha256_file(path)
    r("openssl", "dgst", "-sha256", path).split(" ").last
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
      r "qemu-img", "convert", "-p", "-f", initial_format, "-O", "raw", temp_path, image_path
    end
  end
end
