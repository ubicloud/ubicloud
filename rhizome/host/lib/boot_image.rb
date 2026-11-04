# frozen_string_literal: true

require "fileutils"
require "uri"
require_relative "../../common/lib/arch"
require_relative "../../common/lib/util"

class BootImage
  # A transfer that stopped early and a transfer that arrived whole but wrong
  # need different remedies, and both were reported as "Invalid SHA256 sum."
  # The byte count is checked first and raises this instead, so the digest gate
  # is left to mean exactly one thing: the bytes are wrong.
  class TruncatedDownload < RuntimeError; end

  # One pass is one htcat run or one ranged curl resume. Five bounds a single
  # run of this program; Prog::DownloadBootImage's own budget of ten restarts
  # is the outer loop, and a retained partial is what makes those restarts
  # cheap.
  MAX_DOWNLOAD_PASSES = 5

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

    # Two VMs lazily getting the same image refuse rather than race, on either
    # path and with the same sentence: both take a non-blocking exclusive flock
    # over the temporary file (see #open_partial).
    temp_file_name = @version.nil? ? @name : "#{@name}-#{@version}"
    temp_path = File.join(@image_root, "#{temp_file_name}#{ext}.tmp")
    keep_partial = false
    begin
      file_sha256sum = if use_htcat
        htcat_image(url, temp_path, ca_path)
      else
        curl_image(url, temp_path, ca_path)
      end
      verify_sha256sum(file_sha256sum, sha256sum)
      convert_image(temp_path, init_format)
    rescue TruncatedDownload
      # The partial used to be deleted here, so every restart re-fetched the
      # whole object -- tens of gigabytes for a large image, up to ten times
      # over. The bytes are kept only so the next attempt fetches the tail.
      # Nothing trusts them: the next run re-measures the file and re-hashes
      # all of it, and the digest gate above is unchanged.
      keep_partial = File.exist?(temp_path) && File.size(temp_path).positive?
      raise
    ensure
      rm_if_exists(temp_path) unless keep_partial
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
    # open_partial, not File::EXCL. Both paths name the temporary file
    # identically and the htcat path now retains a short one for the next
    # attempt to resume, so EXCL here would crash the curl path with
    # Errno::EEXIST on a retained partial instead of starting the download
    # over. The flock keeps the refuse-rather-than-race guarantee without the
    # collision, and a crashed process releases it where a leftover file would
    # have persisted. The shell redirect below truncates, so the retained bytes
    # are discarded; the curl path has no resume of its own.
    open_partial(temp_path) do
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

  def htcat_image(url, temp_path, ca_path = nil)
    expected_size = remote_size(url, ca_path)
    open_partial(temp_path) do
      last_error = nil
      pass = 0
      while pass < MAX_DOWNLOAD_PASSES
        pass += 1
        before = File.size(temp_path)
        # The last error is kept across a later successful-but-short pass: the
        # tool failure that broke the transfer is the cause worth naming.
        error = attempt_pass(url, temp_path, ca_path, before, expected_size, pass)
        last_error = error if error
        # Without a known size there is no way to tell a finished transfer from
        # a short one, so there is exactly one pass.
        break if expected_size.nil?

        size = File.size(temp_path)
        break if size >= expected_size || size == before
      end
      verify_size(temp_path, expected_size, last_error)
      sha256_file(temp_path)
    end
  end

  # htcat has no resume of its own, so the first pass is htcat and every later
  # pass is curl -C -, which stats the partial and asks for exactly the missing
  # range. The pass line goes to stderr, which the daemonizer captures and
  # Prog::DownloadBootImage cats on a Failed check, so the attempt count is
  # recorded next to the strand's own restart count.
  def attempt_pass(url, temp_path, ca_path, before, expected_size, pass)
    tool = before.zero? ? :htcat : :curl
    warn "boot image download pass #{pass} of #{MAX_DOWNLOAD_PASSES}: #{tool} from #{before} of #{expected_size || "unknown"} bytes"
    if tool == :htcat
      run_htcat(url, temp_path)
    else
      resume_download(url, temp_path, ca_path)
    end
    nil
  rescue CommandFail => e
    message = tool_failure(tool, e, File.size(temp_path), expected_size)
    # With no known object size there is nothing to resume against, so the
    # tool's own failure is the whole answer and it is raised by name.
    raise message if expected_size.nil?

    warn message
    message
  end

  def resume_download(url, temp_path, ca_path)
    args = ["curl", "-f", "-sS", "-L", "-C", "-", "-o", temp_path]
    args += ["--cacert", ca_path] if ca_path
    r(*args, url)
  end

  # File::EXCL provoked a crash rather than a race when two VMs lazily fetch
  # the same image. A partial that now outlives the process makes EXCL
  # impossible, so the same guarantee is taken with a non-blocking exclusive
  # flock, which a crashed process also releases. Both download paths come
  # through here, so the refusal reads the same either way.
  def open_partial(temp_path)
    File.open(temp_path, File::RDWR | File::CREAT, 0o644) do |file|
      fail "Boot image download already in progress: #{temp_path}" unless file.flock(File::LOCK_EX | File::LOCK_NB)

      yield
    end
  end

  # The presigned URL is signed for GET, so the object size is read with a
  # one-byte ranged GET rather than a HEAD, which the same signature would not
  # cover. An S3-compatible store answers 206 with
  # "Content-Range: bytes 0-0/<total>". A store that ignores Range answers 200,
  # there is then nothing to resume against, and nil puts the caller back on
  # the previous single-pass behaviour rather than refusing the download.
  def remote_size(url, ca_path)
    args = ["curl", "-f", "-sS", "-L", "--max-time", "60", "-r", "0-0", "-D", "-", "-o", File::NULL]
    args += ["--cacert", ca_path] if ca_path
    headers = r(*args, url)
    headers[%r{^content-range:\s*bytes\s+\d+-\d+/(\d+)}i, 1]&.to_i
  rescue CommandFail => e
    warn "boot image size probe failed, so the download cannot be resumed: #{e.stderr.to_s.strip}"
    nil
  end

  # Runs BEFORE verify_sha256sum, so a short file is named as a truncation and
  # only a whole-but-wrong file reaches the unchanged fail-closed digest gate.
  def verify_size(temp_path, expected_size, last_error)
    return if expected_size.nil?

    size = File.size(temp_path)
    return if size == expected_size
    fail "Boot image download overran: #{size} of #{expected_size} bytes expected" if size > expected_size

    cause = last_error ? "last error: #{last_error}" : "the transfer ended early with no error from htcat or curl"
    raise TruncatedDownload, "Truncated boot image download: #{size} of #{expected_size} bytes (#{expected_size - size} short); #{cause}"
  end

  # Names the tool that failed and repeats its stderr, so the daemonizer log
  # the prog cats on a Failed check carries the cause and not just a symptom.
  def tool_failure(tool, error, size, expected_size = nil)
    counted = expected_size.nil? ? "#{size} bytes" : "#{size} of #{expected_size} bytes"
    "#{tool} failed after #{counted}: #{error.stderr.to_s.strip}"
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
