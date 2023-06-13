# frozen_string_literal: true

require "excon"
class Hosting::Apis
  def self.pull_ips(vm_host)
    if vm_host.provider == HetznerHost::PROVIDER_NAME
      vm_host.hetzner_host.api.pull_ips
    else
      raise "unknown provider #{vm_host.provider}"
    end
  end
end
