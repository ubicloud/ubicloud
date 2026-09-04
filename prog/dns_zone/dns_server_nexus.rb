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
    nap 60 * 60
  end
end
