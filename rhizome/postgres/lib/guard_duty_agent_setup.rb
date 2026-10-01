# frozen_string_literal: true

require "tmpdir"
require_relative "../../common/lib/util"
require_relative "../../common/lib/arch"

# The agent carries no redistribution grant, so it is installed from AWS's
# regional bucket at runtime rather than baked into the image.
class GuardDutyAgentSetup
  VERSION = "1.9.2"
  PACKAGE_ARCH = Arch.render(x64: "amd64", arm64: "arm64")
  CHECKSUM = Arch.render(
    x64: "b35b3f25da7b2f829b9972f6d32f44adda77178e5e380fd839f6f40f95933bb2",
    arm64: "78b336c6f14d6677a0c57810829e2e794113435bffc7f77bbc586586224cdf80",
  )
  BUCKET_OWNERS = {
    "us-west-2" => "733349766148",
    "us-east-1" => "593207742271",
    "us-east-2" => "307168627858",
    "ap-southeast-2" => "005257825471",
    "eu-west-1" => "694911143906",
    "eu-central-1" => "323658145986",
  }.freeze

  def initialize(region)
    @region = region
  end

  def run
    return if r("dpkg-query", "--show", "--showformat=${Version}", "amazon-guardduty-agent", expect: [0, 1]) == VERSION

    url = "https://#{BUCKET_OWNERS.fetch(@region)}-#{@region}-guardduty-agent-deb-artifacts.s3.#{@region}.amazonaws.com/#{VERSION}/#{PACKAGE_ARCH}/amazon-guardduty-agent-#{VERSION}.#{PACKAGE_ARCH}.deb"
    Dir.mktmpdir do |dir|
      package = File.join(dir, "amazon-guardduty-agent.deb")
      fail "Invalid SHA-256 digest" unless curl_file(url, package) == CHECKSUM
      r "dpkg", "-i", package
    end
  end
end
