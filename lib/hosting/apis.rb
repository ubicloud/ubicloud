# frozen_string_literal: true

require "excon"
class Hosting::Apis
  def self.pull_ips(vm_host)
    if vm_host.provider_name == HostProvider::HETZNER_PROVIDER_NAME
      vm_host.provider.api.pull_ips
    else
      raise "unknown provider #{vm_host.provider_name}"
    end
  end

  def self.reimage_server(vm_host)
    if vm_host.provider_name == HostProvider::HETZNER_PROVIDER_NAME
      vm_host.provider.api.reimage(vm_host.provider.server_identifier)
    else
      raise "unknown provider #{vm_host.provider_name}"
    end
  end

  # Cuts power to a Server and starts it again. This forcefully stops it
  # without giving the Server operating system time to gracefully stop. This
  # may lead to data loss, it’s equivalent to pulling the power cord and
  # plugging it in again. Reset should only be used when reboot does not work.
  def self.hardware_reset_server(vm_host)
    if vm_host.provider_name == HostProvider::HETZNER_PROVIDER_NAME
      vm_host.provider.api.reset(vm_host.provider.server_identifier)
    else
      raise "unknown provider #{vm_host.provider_name}"
    end
  end

  def self.pull_data_center(vm_host)
    if vm_host.provider_name == HostProvider::HETZNER_PROVIDER_NAME
      vm_host.provider.api.pull_dc(vm_host.provider.server_identifier)
    else
      raise "unknown provider #{vm_host.provider_name}"
    end
  end

  def self.set_server_name(vm_host)
    if vm_host.provider_name == HostProvider::HETZNER_PROVIDER_NAME
      vm_host.provider.api.set_server_name(vm_host.provider.server_identifier, vm_host.ubid)
    else
      raise "unknown provider #{vm_host.provider_name}"
    end
  end
end
