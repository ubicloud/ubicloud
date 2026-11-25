# frozen_string_literal: true

require_relative "../../common/lib/util"

class VictoriaMetricsSetup
  # Upstream publishes a checksums.txt next to each tarball; these are the
  # digests it lists for the linux-amd64 builds.
  CHECKSUMS = {
    "v1.157.0" => {
      "victoria-metrics" => "7b31192da6cf805b8b9244a904b022948e8022a067a822c30cb9f94600d0c387",
      "vmutils" => "f797ecaa5045a8f8095a813a3b3e2ef697e4086affcc174547cf559768044862",
    },
  }.freeze

  def initialize(argv)
    fail "expected a single argument, a VictoriaMetrics version like v1.157.0, got #{argv.length}" unless argv.length == 1

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
