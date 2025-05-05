# frozen_string_literal: true

require "fileutils"
require_relative "../../common/lib/arch"

module VhostBackend
  class Version < Struct.new(:version, :sha256)
    DEFAULT = if Arch.x64?
      new("0.1-1", "670f1003f105771f89c821b04c34322e7c5ee0c71dcc6188dc8497be7ecb46a3")
    else
      new("0.1-1", "56046afbac44a095858fba7fca9e02db35dfd4d10ed66a2e5db1977f65dd51c8")
    end

    def url
      "https://github.com/ubicloud/ubiblk/releases/download/v#{version}/vhost-backend-#{Arch.x64? ? "x86" : "arm64"}"
    end

    def dir
      "/opt/vhost-backend/v#{version}"
    end

    def bin_path
      "#{dir}/vhost-backend"
    end

    def download
      download_file(url, bin_path, sha256)
    end

    def download_file(url, path, sha256)
      return if File.exist?(path)
      FileUtils.mkdir_p(dir)

      safe_write_to_file(path) do |f|
        unless curl_file(url, f.path) == sha256
          fail "Invalid SHA-256 digest"
        end
      end

      FileUtils.chmod "a+x", path
    end
  end
end
