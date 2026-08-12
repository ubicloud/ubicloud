# frozen_string_literal: true

require_relative "../../common/lib/util"

class VictoriaMetricsSetup
  # Upstream publishes a checksums.txt next to each tarball; these are the
  # digests it lists for the linux-amd64 builds.
  CHECKSUMS = {
    "v1.149.0" => {
      "victoria-metrics" => "6695fbee54bca58b78162ddf785c387b24641e57dfe4f3f743fb241f41dc3697",
      "vmutils" => "1ccaa92acf4f2fcba03d8c197f1b1da7194cc4777ecf45ab5b212bd6ed52be58",
    },
  }.freeze

  def initialize(argv)
    fail "expected a single argument, a VictoriaMetrics version like v1.149.0, got #{argv.length}" unless argv.length == 1

    @version = argv[0]
    fail "no VictoriaMetrics checksums for version #{@version.inspect}" unless CHECKSUMS.key?(@version)
  end

  def run
    install("victoria-metrics")
    install("vmutils")
  end

  def install(component)
    tarball = "#{component}-linux-amd64-#{@version}.tar.gz"
    url = "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/#{@version}/#{tarball}"

    fail "Invalid SHA-256 digest" unless curl_file(url, tarball) == CHECKSUMS.fetch(@version).fetch(component)

    r "tar", "xfz", tarball, "-C", "/usr/local/bin", "--no-same-owner"
    r "rm", tarball
  end
end
