# frozen_string_literal: true

require "ulid"

class Clover
  class VmHostShadow
    attr_accessor :id, :host, :state, :location, :ip6, :vms_count, :total_cores, :used_cores, :public_keys, :ndp_needed

    def initialize(vm_host)
      @id = ULID.from_uuidish(vm_host.id).to_s.downcase
      @host = vm_host.sshable.host
      @state = vm_host.allocation_state
      @location = vm_host.location
      @ip6 = vm_host.ip6
      @vms_count = vm_host.vms.count
      @total_cores = vm_host.total_cores
      @used_cores = vm_host.used_cores
      @public_keys = vm_host.sshable.keys.map(&:public_key)
      @ndp_needed = vm_host.ndp_needed
    end
  end

  hash_branch("vm-host") do |r|
    unless vm_host_allowed?
      fail Authorization::Unauthorized
    end

    r.get true do
      @vm_hosts = VmHost.eager(:sshable, :vms).all.map { |vm_host| VmHostShadow.new(vm_host) }

      view "vm_host/index"
    end

    r.post true do
      st = Prog::Vm::HostNexus.assemble(
        r.params["hostname"],
        location: r.params["location"],
        ndp_needed: r.params.key?("ndp-needed")
      )

      flash["notice"] = "You need to add SSH public keys to your host, so the control plane can connect to the host as root via SSH."

      r.redirect "/vm-host/#{VmHostShadow.new(st.vm_host).id}"
    end

    r.on "create" do
      r.get true do
        view "vm_host/create"
      end
    end

    r.is String do |vm_ulid|
      vm_host = VmHost[id: ULID.parse(vm_ulid).to_uuidish]

      unless vm_host
        response.status = 404
        r.halt
      end

      r.get true do
        @vm_host = VmHostShadow.new(vm_host)
        @vms = vm_host.vms.map { |vm| VmShadow.new(vm) }

        view "vm_host/show"
      end
    end
  end
end
