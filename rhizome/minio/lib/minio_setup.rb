# frozen_string_literal: true

require_relative "../../common/lib/util"

class MinioSetup
  # Upstream publishes a .sha256sum next to each package; these are the release
  # tags that serve the linux-amd64 builds and the digests it lists for them.
  RELEASES = {
    "minio_20250723155402.0.0_amd64" => {
      tag: "RELEASE.2025-07-23T15-54-02Z",
      checksum: "a6ff2d7424206c3d8be43bd5eac159e49ea57780ef1d7fb3afbe47227650a62d",
    },
  }.freeze

  def initialize(argv)
    fail "expected a single argument, a minio version like minio_20250723155402.0.0_amd64, got #{argv.length}" unless argv.length == 1

    @version = argv[0]
    fail "no minio checksum for version #{@version.inspect}" unless RELEASES.key?(@version)
  end

  def run
    package = "#{@version}.deb"
    release = RELEASES.fetch(@version)
    url = "https://github.com/minio/minio/releases/download/#{release.fetch(:tag)}/#{package}"

    fail "Invalid SHA-256 digest" unless curl_file(url, package) == release.fetch(:checksum)

    r "dpkg", "-i", package
    r "rm", package
    r "systemctl enable minio.service"
  end
end
