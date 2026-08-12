# frozen_string_literal: true

require_relative "../../common/lib/util"

class MinioSetup
  # Upstream publishes a .sha256sum next to each package; these are the digests
  # it lists for the linux-amd64 builds.
  CHECKSUMS = {
    "minio_20250723155402.0.0_amd64" => "a6ff2d7424206c3d8be43bd5eac159e49ea57780ef1d7fb3afbe47227650a62d",
  }.freeze

  def initialize(argv)
    fail "expected a single argument, a minio version like minio_20250723155402.0.0_amd64, got #{argv.length}" unless argv.length == 1

    @version = argv[0]
    fail "no minio checksum for version #{@version.inspect}" unless CHECKSUMS.key?(@version)
  end

  def run
    package = "#{@version}.deb"
    url = "https://dl.min.io/server/minio/release/linux-amd64/archive/#{package}"

    fail "Invalid SHA-256 digest" unless curl_file(url, package) == CHECKSUMS.fetch(@version)

    r "dpkg", "-i", package
    r "rm", package
    r "systemctl enable minio.service"
  end
end
