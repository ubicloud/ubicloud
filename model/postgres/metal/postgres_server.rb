# frozen_string_literal: true

class PostgresServer < Sequel::Model
  module Metal
    private

    def metal_add_provider_configs(configs)
      # nothing
    end

    def metal_refresh_walg_blob_storage_credentials
      vm.sshable.cmd("sudo tee /usr/lib/ssl/certs/blob_storage_ca.crt > /dev/null", stdin: timeline.blob_storage.root_certs)
    end

    def metal_storage_device_paths
      [vm.vm_storage_volumes.find { it.boot == false }.device_path]
    end

    def metal_attach_s3_policy_if_needed
      # nothing
    end

    def metal_increment_s3_new_timeline
    end

    def metal_lockout_mechanisms
      ["pg_stop", "hba", "host_routing"]
    end
  end
end
