# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "../../common/lib/arch"

# htcat is able to download a file from signed URLs concurrently.
class HtcatSetup
  VERSION = "2.0.0-ubi1"
  CHECKSUM = Arch.render(
    x64: "81876d39ed892e07705114e8ebc48eea112f6f514a9c296d286461d22a0f24d3",
    arm64: "d43bfc8693d2e833b81110f6f392d2c1486716d667e844140fc5d91f0b34f744",
  )

  def run
    tarball = "htcat_#{VERSION}_linux_#{Arch.render(x64: "amd64", arm64: "arm64")}.tar.gz"
    url = "https://github.com/ubicloud/htcat/releases/download/v#{VERSION}/#{tarball}"

    fail "Invalid SHA-256 digest" unless curl_file(url, tarball) == CHECKSUM

    r "tar", "xfz", tarball, "-C", "/usr/local/bin", "--no-same-owner", "htcat"
    r "rm", tarball
  end
end
