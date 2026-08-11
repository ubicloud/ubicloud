# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"

class ParseableSetup
  BIN_PATH = "/usr/local/bin/parseable"

  # Upstream publishes only a SHA-1 in checksum.txt, so these are the SHA-256
  # digests of the artifacts that SHA-1 matched.
  CHECKSUMS = {
    "v2.6.5" => "4beeca018f3d60e8fb1b8eccb8d2d493f6676dd9567b489d8923f952fa5fa9ef",
  }.freeze

  def initialize(argv)
    fail "expected a single argument, a parseable version like v2.6.5, got #{argv.length}" unless argv.length == 1

    @version = argv[0]
    fail "no parseable checksum for version #{@version.inspect}" unless CHECKSUMS.key?(@version)
  end

  def run
    url = "https://github.com/parseablehq/parseable/releases/download/#{@version}/Parseable_OSS_x86_64-unknown-linux-gnu"

    safe_write_to_file(BIN_PATH) do |f|
      fail "Invalid SHA-256 digest" unless curl_file(url, f.path) == CHECKSUMS.fetch(@version)
    end
    FileUtils.chmod "a+x", BIN_PATH
  end
end
