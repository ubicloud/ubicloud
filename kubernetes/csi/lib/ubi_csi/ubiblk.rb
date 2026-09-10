# frozen_string_literal: true

require "fileutils"
require_relative "service_helper"

module Csi
  class Ubiblk
    include ServiceHelper

    VERSION = "v0.5.1"
    BINARIES = %w[ublk-backend init-metadata remote-stripe-server].freeze
    IMAGE_DIR = "/opt/ubiblk/#{VERSION}"
    # The node's /opt/ubiblk/<version>, as this container sees it.
    HOST_DIR = "/host/opt/ubiblk/#{VERSION}"

    def initialize(logger:)
      @logger = logger
      @req_id = "ubiblk-setup"
    end

    def setup
      stage_binaries
      load_kernel_module
    end

    def stage_binaries
      FileUtils.mkdir_p(HOST_DIR)
      BINARIES.each do |name|
        path = File.join(HOST_DIR, name)
        next if File.executable?(path)

        tmp_path = "#{path}.tmp"
        FileUtils.cp(File.join(IMAGE_DIR, name), tmp_path)
        File.chmod(0o755, tmp_path)
        File.rename(tmp_path, path)
        log_with_id(@req_id, "Staged #{name} at #{path}")
      end
    end

    def load_kernel_module
      output, status = run_cmd("nsenter", "-t", "1", "-a", "modprobe", "ublk_drv", req_id: @req_id)
      raise "Failed to load the ublk_drv kernel module: #{output}" unless status.success?
    end
  end
end
