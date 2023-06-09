# frozen_string_literal: true

require "ulid"

class Clover
  hash_branch("vm-host") do |r|
    unless vm_host_allowed?
      fail Authorization::Unauthorized
    end

    @serializer = Serializers::Web::VmHost

    r.get true do
      @vm_hosts = serialize(VmHost.eager(:sshable, :vms).all)

      view "vm_host/index"
    end

    r.post true do
      st = Prog::Vm::HostNexus.assemble(
        r.params["hostname"],
        location: r.params["location"],
        ndp_needed: r.params.key?("ndp-needed")
      )

      flash["notice"] = "You need to add SSH public keys to your host, so the control plane can connect to the host as root via SSH."

      r.redirect "/vm-host/#{st.vm_host.ulid}"
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
        @vm_host = serialize(vm_host, :detail)

        view "vm_host/show"
      end
    end
  end
end
