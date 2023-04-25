# frozen_string_literal: true

require "ulid"

class Clover
  class VmHostShadow
    attr_accessor :id, :host, :state, :location, :ip6, :vms_count

    def initialize(vm_host)
      @id = ULID.from_uuidish(vm_host.id).to_s.downcase
      @host = vm_host.sshable.host
      @state = vm_host.allocation_state
      @location = vm_host.location
      @ip6 = vm_host.ip6
      @vms_count = vm_host.vms.count
    end
  end

  hash_branch("vm-host") do |r|
    r.get true do
      @vm_hosts = VmHost.eager(:sshable, :vms).all.map { |vm_host| VmHostShadow.new(vm_host) }

      view "vm_host/index"
    end

    r.post true do
      Prog::Vm::HostNexus.assemble(
        r.params["hostname"],
        location: r.params["location"]
      )

      flash["notice"] = "'#{r.params["hostname"]}' host will be ready in a few minutes"

      r.redirect "/vm-host"
    end

    r.on "create" do
      r.get true do
        @ssh_keys = if Config.development?
          begin
            agent = Net::SSH::Authentication::Agent.connect
            agent.identities.map { |pub| SshKey.public_key(pub) }
          ensure
            agent.close
          end
        end

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
