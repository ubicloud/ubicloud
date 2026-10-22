# frozen_string_literal: true

require_relative "../lib/boot_image"
require "openssl"
require "base64"
require "shellwords"
require "tmpdir"

RSpec.describe BootImage do
  subject(:bi) { described_class.new("ubuntu-jammy", "20240110") }

  describe "#download" do
    it "can use an image that's already downloaded" do
      expect(File).to receive(:exist?).with("/var/storage/images/ubuntu-jammy-20240110.raw").and_return(true)
      expect(bi).not_to receive(:curl_image)
      bi.download(url: "url", ca_path: "ca_path", sha256sum: "sha256sum")
    end

    it "can download an image" do
      expect(File).to receive(:exist?).with("/var/storage/images/ubuntu-jammy-20240110.raw").and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/images")
      expect(bi).to receive(:image_ext).with("url").and_return(".img")
      tmp_path = "/var/storage/images/ubuntu-jammy-20240110.img.tmp"
      expect(bi).to receive(:curl_image).with("url", tmp_path, "ca_path").and_return("returned_sha256sum")
      expect(bi).to receive(:verify_sha256sum).with("returned_sha256sum", "sha256sum")
      expect(bi).to receive(:convert_image).with(tmp_path, "qcow2")
      expect(FileUtils).to receive(:rm_r).with(tmp_path)

      bi.download(url: "url", ca_path: "ca_path", sha256sum: "sha256sum")
    end

    it "can download an unversioned image" do
      bi_no_version = described_class.new("ubuntu-jammy", nil)
      expect(File).to receive(:exist?).with("/var/storage/images/ubuntu-jammy.raw").and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/images")
      expect(bi_no_version).to receive(:image_ext).with("url").and_return(".img")
      tmp_path = "/var/storage/images/ubuntu-jammy.img.tmp"
      expect(bi_no_version).to receive(:curl_image).with("url", tmp_path, nil).and_return("sha256sum")
      expect(bi_no_version).to receive(:verify_sha256sum).with("sha256sum", nil)
      expect(bi_no_version).to receive(:convert_image).with(tmp_path, "qcow2")
      expect(FileUtils).to receive(:rm_r).with(tmp_path)
      bi_no_version.download(url: "url")
    end

    it "can download an image with htcat" do
      expect(File).to receive(:exist?).with("/var/storage/images/ubuntu-jammy-20240110.raw").and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/images")
      expect(bi).to receive(:image_ext).with("url").and_return(".img")
      tmp_path = "/var/storage/images/ubuntu-jammy-20240110.img.tmp"
      expect(bi).to receive(:htcat_image).with("url", tmp_path, "ca_path").and_return("returned_sha256sum")
      expect(bi).to receive(:verify_sha256sum).with("returned_sha256sum", "sha256sum")
      expect(bi).to receive(:convert_image).with(tmp_path, "qcow2")
      expect(FileUtils).to receive(:rm_r).with(tmp_path)

      bi.download(url: "url", ca_path: "ca_path", sha256sum: "sha256sum", use_htcat: true)
    end
  end

  describe "#image_ext" do
    it "can handle image without query params" do
      url = "http://minio.ubicloud.com:9000/ubicloud-images/ubuntu-22.04-x64.vhd"
      expect(bi.image_ext(url)).to eq(".vhd")
    end

    it "can handle image with query params" do
      url = "http://minio.ubicloud.com:9000/ubicloud-images/ubuntu-22.04-x64.vhd?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=user%2F20240112%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20240112T132931Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Signature=aabbcc"
      expect(bi.image_ext(url)).to eq(".vhd")
    end
  end

  describe "#image_path" do
    it "returns path with version when version is set" do
      expect(bi.image_path).to eq("/var/storage/images/ubuntu-jammy-20240110.raw")
    end

    it "returns path without version when version is nil" do
      bi_no_version = described_class.new("ubuntu-jammy", nil)
      expect(bi_no_version.image_path).to eq("/var/storage/images/ubuntu-jammy.raw")
    end

    it "uses custom image_root when provided" do
      bi_custom = described_class.new("ubuntu-jammy", "20240110", image_root: "/custom/images")
      expect(bi_custom.image_path).to eq("/custom/images/ubuntu-jammy-20240110.raw")
    end
  end

  describe "#initial_format" do
    it "fails if initial image has unsupported format" do
      expect { bi.initial_format(".iso") }.to raise_error RuntimeError, "Unsupported boot_image format: .iso"
    end

    it "returns raw for .raw extension" do
      expect(bi.initial_format(".raw")).to eq("raw")
    end

    it "returns vpc for .vhd extension" do
      expect(bi.initial_format(".vhd")).to eq("vpc")
    end

    it "returns qcow2 for .qcow2 and .img extensions" do
      expect(bi.initial_format(".qcow2")).to eq("qcow2")
      expect(bi.initial_format(".img")).to eq("qcow2")
    end
  end

  # Exercised against real files for the same reason the htcat path is: the
  # question this asks is what happens to a .tmp that is already on disk, and a
  # mocked File.open cannot answer it.
  describe "#curl_image" do
    let(:directory) { Dir.mktmpdir("boot-image-") }
    let(:cbi) { described_class.new("ubuntu-jammy", "20240110", image_root: directory) }
    let(:url) { "https://store.example/ubuntu-jammy-x64-20240110.raw" }
    let(:temp_path) { "#{directory}/ubuntu-jammy-20240110.raw.tmp" }
    let(:curl_command) { "bash -c #{"set -o pipefail; curl --fail --location #{url} | tee >(openssl dgst -sha256) > #{temp_path}".shellescape}" }
    let(:digest) { "81fae9cc21e2b1e3a9a4526c7dad3131b668e346c580702235ad4d02645d9455" }

    after { FileUtils.remove_entry(directory) }

    it "digests the stream curl wrote" do
      expect(cbi).to receive(:_run_command).with(curl_command) {
        File.write(temp_path, "image bytes")
        "SHA2-256(stdin)= #{digest}\n"
      }

      expect(cbi.curl_image(url, temp_path, nil)).to eq(digest)
    end

    it "sends the CA bundle when one is configured" do
      with_ca = "bash -c #{"set -o pipefail; curl --fail --location #{url} --cacert /ca.crt | tee >(openssl dgst -sha256) > #{temp_path}".shellescape}"
      expect(cbi).to receive(:_run_command).with(with_ca).and_return("SHA2-256(stdin)= #{digest}\n")

      expect(cbi.curl_image(url, temp_path, "/ca.crt")).to eq(digest)
    end

    # The htcat path retains a short .tmp so the next attempt can resume it, and
    # both paths name that file identically. File::EXCL made the curl path crash
    # with Errno::EEXIST on one, which is why the two now open it the same way.
    it "starts over a partial the htcat path retained" do
      File.write(temp_path, "half an im")
      expect(cbi).to receive(:_run_command).with(curl_command) {
        File.write(temp_path, "image bytes")
        "SHA2-256(stdin)= #{digest}\n"
      }

      expect(cbi.curl_image(url, temp_path, nil)).to eq(digest)
      expect(File.read(temp_path)).to eq("image bytes")
    end

    # This came from File::EXCL. The guarantee is kept, by the same non-blocking
    # flock the htcat path takes, so two VMs lazily fetching one image still
    # refuse rather than race -- and now they refuse with the same sentence
    # whichever path they are on.
    it "refuses a second download of the same image while one holds the partial" do
      File.open(temp_path, File::RDWR | File::CREAT, 0o644) do |held|
        expect(held.flock(File::LOCK_EX | File::LOCK_NB)).to eq(0)
        expect { cbi.curl_image(url, temp_path, nil) }.to raise_error(
          RuntimeError, "Boot image download already in progress: #{temp_path}",
        )
      end
    end
  end

  # The htcat path is exercised against real files in a private directory: the
  # bytes on disk are what a truncated transfer is diagnosed from, so a mocked
  # File.open would test nothing. Only the commands themselves are mocked, and
  # each mock writes the bytes its real tool would have written.
  describe "#htcat_image" do
    let(:directory) { Dir.mktmpdir("boot-image-") }
    let(:hbi) { described_class.new("ubuntu-jammy", "20240110", image_root: directory) }
    let(:url) { "https://store.example/ubuntu-jammy-x64-20240110.raw" }
    let(:temp_path) { "#{directory}/ubuntu-jammy-20240110.raw.tmp" }
    let(:htcat_command) { "bash -c #{"htcat -parallelism=12 -max-fragment-size=32 #{url} > #{temp_path}".shellescape}" }
    let(:digest_command) { ["openssl", "dgst", "-sha256", temp_path] }
    let(:probe_command) { ["curl", "-f", "-sS", "-L", "--max-time", "60", "-r", "0-0", "-D", "-", "-o", File::NULL, url] }
    let(:resume_command) { ["curl", "-f", "-sS", "-L", "-C", "-", "-o", temp_path, url] }
    let(:probe_headers) { "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/11\r\nContent-Length: 1\r\n\r\n" }

    after { FileUtils.remove_entry(directory) }

    it "runs htcat with no pipe and digests the finished file" do
      expect(hbi).to receive(:_run_command).with(*probe_command).and_return(probe_headers)
      expect(hbi).to receive(:_run_command).with(htcat_command) {
        File.write(temp_path, "image bytes")
        ""
      }
      expect(hbi).to receive(:_run_command).with(*digest_command)
        .and_return("SHA2-256(#{temp_path})= 81fae9cc21e2b1e3a9a4526c7dad3131b668e346c580702235ad4d02645d9455\n")

      expect(hbi.htcat_image(url, temp_path)).to eq("81fae9cc21e2b1e3a9a4526c7dad3131b668e346c580702235ad4d02645d9455")
    end

    it "names htcat and repeats htcat's stderr when htcat itself fails" do
      expect(hbi).to receive(:_run_command).with(*probe_command).and_return("HTTP/1.1 200 OK\r\n\r\n")
      expect(hbi).to receive(:_run_command).with(htcat_command) do
        File.write(temp_path, "partial")
        raise CommandFail.new("command failed: #{htcat_command}", "", "htcat: fragment 7: unexpected EOF\n")
      end

      expect { hbi.htcat_image(url, temp_path) }.to raise_error(
        RuntimeError, "htcat failed after 7 bytes: htcat: fragment 7: unexpected EOF",
      )
    end

    it "counts the bytes against the object size before the digest is taken" do
      expect(hbi).to receive(:_run_command).with(*probe_command).and_return(probe_headers)
      expect(hbi).to receive(:_run_command).with(htcat_command) {
        File.write(temp_path, "image")
        ""
      }
      expect(hbi).not_to receive(:_run_command).with(*digest_command)

      expect { hbi.htcat_image(url, temp_path) }.to raise_error(
        BootImage::TruncatedDownload,
        "Truncated boot image download: 5 of 11 bytes (6 short); the transfer ended early with no error from htcat or curl",
      )
    end

    it "refuses a file that overran the object size" do
      expect(hbi).to receive(:_run_command).with(*probe_command).and_return(probe_headers)
      expect(hbi).to receive(:_run_command).with(htcat_command) {
        File.write(temp_path, "image bytes and more")
        ""
      }

      expect { hbi.htcat_image(url, temp_path) }.to raise_error(
        RuntimeError, "Boot image download overran: 20 of 11 bytes expected",
      )
    end

    it "resumes the missing tail with a ranged curl instead of fetching the object again" do
      expect(hbi).to receive(:_run_command).with(*probe_command).and_return(probe_headers)
      expect(hbi).to receive(:_run_command).with(htcat_command) {
        File.write(temp_path, "image")
        ""
      }
      expect(hbi).to receive(:_run_command).with(*resume_command) {
        File.open(temp_path, "ab") { |f| f.write(" bytes") }
        ""
      }
      expect(hbi).to receive(:_run_command).with(*digest_command).and_return("SHA2-256(x)= abc\n")

      expect(hbi.htcat_image(url, temp_path)).to eq("abc")
      expect(File.read(temp_path)).to eq("image bytes")
    end

    it "resumes a partial an earlier attempt left behind, without running htcat" do
      File.write(temp_path, "image")
      expect(hbi).to receive(:_run_command).with(*probe_command).and_return(probe_headers)
      expect(hbi).not_to receive(:_run_command).with(htcat_command)
      expect(hbi).to receive(:_run_command).with(*resume_command) {
        File.open(temp_path, "ab") { |f| f.write(" bytes") }
        ""
      }
      expect(hbi).to receive(:_run_command).with(*digest_command).and_return("SHA2-256(x)= abc\n")

      expect(hbi.htcat_image(url, temp_path)).to eq("abc")
    end

    it "stops on the first pass that moves no bytes, and names the last tool error" do
      expect(hbi).to receive(:_run_command).with(*probe_command).and_return(probe_headers)
      expect(hbi).to receive(:_run_command).with(htcat_command) do
        File.write(temp_path, "image")
        raise CommandFail.new("command failed", "", "htcat: fragment 7: unexpected EOF\n")
      end
      expect(hbi).to receive(:_run_command).with(*resume_command).once.and_return("")

      expect { hbi.htcat_image(url, temp_path) }.to raise_error(
        BootImage::TruncatedDownload,
        "Truncated boot image download: 5 of 11 bytes (6 short); last error: htcat failed after 5 of 11 bytes: htcat: fragment 7: unexpected EOF",
      )
    end

    it "gives up after the pass limit even when every pass moves bytes" do
      expect(hbi).to receive(:_run_command).with(*probe_command).and_return(probe_headers)
      expect(hbi).to receive(:_run_command).with(htcat_command) {
        File.write(temp_path, "i")
        ""
      }
      expect(hbi).to receive(:_run_command).with(*resume_command).exactly(described_class::MAX_DOWNLOAD_PASSES - 1).times {
        File.open(temp_path, "ab") { |f| f.write("x") }
        ""
      }

      expect { hbi.htcat_image(url, temp_path) }.to raise_error(
        BootImage::TruncatedDownload,
        "Truncated boot image download: 5 of 11 bytes (6 short); the transfer ended early with no error from htcat or curl",
      )
    end

    it "refuses a second download of the same image while one holds the partial" do
      expect(hbi).to receive(:_run_command).with(*probe_command).and_return(probe_headers)

      File.open(temp_path, File::RDWR | File::CREAT, 0o644) do |held|
        expect(held.flock(File::LOCK_EX | File::LOCK_NB)).to eq(0)
        expect { hbi.htcat_image(url, temp_path) }.to raise_error(
          RuntimeError, "Boot image download already in progress: #{temp_path}",
        )
      end
    end

    it "passes the CA bundle to the size probe" do
      expect(hbi).to receive(:_run_command)
        .with("curl", "-f", "-sS", "-L", "--max-time", "60", "-r", "0-0", "-D", "-", "-o", File::NULL, "--cacert", "/ca.crt", url)
        .and_return(probe_headers)
      expect(hbi).to receive(:_run_command).with(htcat_command) {
        File.write(temp_path, "image bytes")
        ""
      }
      expect(hbi).to receive(:_run_command).with(*digest_command).and_return("SHA2-256(x)= abc\n")

      expect(hbi.htcat_image(url, temp_path, "/ca.crt")).to eq("abc")
    end
  end

  # The presigned URL is signed for GET, so the object size is read with a
  # one-byte ranged GET rather than a HEAD, and taken from Content-Range.
  describe "#remote_size" do
    let(:url) { "https://store.example/image.raw" }
    let(:probe_command) { ["curl", "-f", "-sS", "-L", "--max-time", "60", "-r", "0-0", "-D", "-", "-o", File::NULL, url] }

    it "reads the total from Content-Range, through a redirect" do
      expect(bi).to receive(:_run_command).with(*probe_command).and_return(
        "HTTP/1.1 302 Found\r\nLocation: https://store.example/redirected\r\n\r\n" \
        "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/80530636800\r\nContent-Length: 1\r\n\r\n",
      )

      expect(bi.remote_size(url, nil)).to eq(80530636800)
    end

    it "returns nil when the store answered without a range" do
      expect(bi).to receive(:_run_command).with(*probe_command)
        .and_return("HTTP/1.1 200 OK\r\nContent-Length: 80530636800\r\n\r\n")

      expect(bi.remote_size(url, nil)).to be_nil
    end

    it "returns nil when the probe itself fails" do
      expect(bi).to receive(:_run_command).with(*probe_command)
        .and_raise(CommandFail.new("command failed", "", "curl: (22) 403"))

      expect(bi.remote_size(url, nil)).to be_nil
    end
  end

  # What survives a failed download is the whole point of the resume: the
  # partial is kept only when the next attempt can use it, and nothing trusts
  # it -- the next run re-measures and re-hashes the whole file.
  describe "#download partial retention" do
    let(:directory) { Dir.mktmpdir("boot-image-") }
    let(:hbi) { described_class.new("ubuntu-jammy", "20240110", image_root: directory) }
    let(:url) { "https://store.example/ubuntu-jammy-x64-20240110.raw" }
    let(:temp_path) { "#{directory}/ubuntu-jammy-20240110.raw.tmp" }
    let(:htcat_command) { "bash -c #{"htcat -parallelism=12 -max-fragment-size=32 #{url} > #{temp_path}".shellescape}" }
    let(:probe_command) { ["curl", "-f", "-sS", "-L", "--max-time", "60", "-r", "0-0", "-D", "-", "-o", File::NULL, url] }
    let(:resume_command) { ["curl", "-f", "-sS", "-L", "-C", "-", "-o", temp_path, url] }
    let(:probe_headers) { "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/11\r\nContent-Length: 1\r\n\r\n" }

    after { FileUtils.remove_entry(directory) }

    it "keeps the bytes already fetched when the download was truncated" do
      expect(hbi).to receive(:_run_command).with(*probe_command).and_return(probe_headers)
      expect(hbi).to receive(:_run_command).with(htcat_command) {
        File.write(temp_path, "image")
        ""
      }
      expect(hbi).to receive(:_run_command).with(*resume_command).once.and_return("")

      expect { hbi.download(url: url, sha256sum: "a" * 64, use_htcat: true) }.to raise_error(BootImage::TruncatedDownload)
      expect(File.read(temp_path)).to eq("image")
    end

    it "removes a temporary file that holds no bytes to resume from" do
      expect(hbi).to receive(:_run_command).with(*probe_command).and_return(probe_headers)
      expect(hbi).to receive(:_run_command).with(htcat_command).and_return("")

      expect { hbi.download(url: url, sha256sum: "a" * 64, use_htcat: true) }.to raise_error(BootImage::TruncatedDownload)
      expect(File.exist?(temp_path)).to be false
    end

    it "removes a whole file the digest gate refused, because resuming it is pointless" do
      expect(hbi).to receive(:_run_command).with(*probe_command).and_return(probe_headers)
      expect(hbi).to receive(:_run_command).with(htcat_command) {
        File.write(temp_path, "image bytes")
        ""
      }
      expect(hbi).to receive(:_run_command).with("openssl", "dgst", "-sha256", temp_path).and_return("SHA2-256(x)= #{"b" * 64}\n")

      expect { hbi.download(url: url, sha256sum: "a" * 64, use_htcat: true) }.to raise_error(RuntimeError, "Invalid SHA256 sum.")
      expect(File.exist?(temp_path)).to be false
    end
  end

  describe "#verify_sha256sum" do
    it "succeeds if sha256 sums match" do
      expect { bi.verify_sha256sum("sha256sum", "sha256sum") }.not_to raise_error
    end

    it "fails if sha256 sums do not match" do
      expect { bi.verify_sha256sum("sha256sum", "invalid") }.to raise_error(RuntimeError, "Invalid SHA256 sum.")
    end

    it "succeeds if expected sha256 sum is nil" do
      expect { bi.verify_sha256sum("sha256sum", nil) }.not_to raise_error
    end
  end

  describe "#convert_image" do
    it "can convert image" do
      expect(bi).to receive(:_run_command).with("qemu-img", "convert", "-p", "-f", "qcow2", "-O", "raw", "/var/storage/images/ubuntu-jammy-20240110.img.tmp", "/var/storage/images/ubuntu-jammy-20240110.raw")
      bi.convert_image("/var/storage/images/ubuntu-jammy-20240110.img.tmp", "qcow2")
    end

    it "does not convert image if it's in raw format already" do
      expect(File).to receive(:rename).with("/var/storage/images/ubuntu-jammy-20240110.img.tmp", "/var/storage/images/ubuntu-jammy-20240110.raw")
      bi.convert_image("/var/storage/images/ubuntu-jammy-20240110.img.tmp", "raw")
    end
  end
end
