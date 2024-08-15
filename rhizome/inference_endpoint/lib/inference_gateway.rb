# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

class InferenceGateway
  def initialize(version, sha)
    fail "BUG: unsupported architecture" unless Arch.x64?
    @version = version
    @sha = sha
  end

  def url
    "https://drive.usercontent.google.com/download?id=1o75CjKsGhnwjXi5BDKykYOTQf2GbIIQz&confirm=xxx"
  end

  def root
    "/opt/inference-gateway"
  end

  def path
    "#{root}/inference-gateway-#{@version}"
  end

  def download
    return if File.exist?(path)
    FileUtils.mkdir_p(root)
    sha256_curl = nil
    safe_write_to_file(path) do |f|
      sha256_curl = curl_file(url, f.path)
      fail "Invalid SHA-256 digest" unless @sha == sha256_curl
    end
    FileUtils.chmod "a+x", path
  end
end
