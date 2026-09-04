# frozen_string_literal: true

class Prog::DnsZone::DnsServerNexus < Prog::Base
  subject_is :dns_server

  def self.assemble(dns_server)
    Strand.new(id: dns_server.id, prog: "DnsZone::DnsServerNexus", label: "wait")
      .insert_conflict(target: :id).save_changes
    Strand[dns_server.id]
  end

  def before_run
    super
    pop "dns server deleted" unless dns_server
  end

  label def wait
    when_configure_set? do
      register_deadline("wait", 15 * 60)
      hop_configure
    end

    nap 60 * 60
  end

  label def configure
    config = dns_server.knot_config
    dns_server.vms.each do |vm|
      next unless dns_server.vms_dataset.where(id: vm.id).any?

      sshable = vm.sshable
      unless sshable.available?
        Prog::PageNexus.assemble(
          "DNS VM #{vm.ubid} unreachable during configuration",
          ["DnsServerVmConfigure", vm.id], vm.ubid,
          resource_id: vm.id,
        )
        Clog.emit("dns server vm unreachable, skipping configure", {vm_ubid: vm.ubid})
        next
      end

      sshable.write_file("/etc/knot/knot.conf", config)
      sshable.cmd("sudo -u knot knotc reload")
      Page.from_tag_parts("DnsServerVmConfigure", vm.id)&.incr_resolve
    rescue *Sshable::SSH_CONNECTION_ERRORS, Sshable::SshError, Net::SSH::Exception => ex
      Clog.emit("dns server vm configuration failed, retrying", Util.exception_to_hash(ex, into: {vm_ubid: vm.ubid}))
      nap 5
    end

    decr_configure
    hop_wait
  end
end
