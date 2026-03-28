# frozen_string_literal: true

require "resolv"

class Prog::CheckDomainBlacklist < Prog::Base
  subject_is :account

  SURBL_LISTS = {
    "DM" => 4,
    "PH" => 8,
    "MW" => 16,
    "CT" => 32,
    "ABUSE" => 64,
    "CR" => 128,
  }.freeze

  # Google Public DNS is used because the system default resolver may not
  # recurse into the multi.surbl.org zone. Per SURBL guidelines, queries
  # should go through a caching recursive resolver, not directly to their
  # authoritative nameservers.
  SURBL_DNS_NAMESERVER = "8.8.8.8"

  label def start
    domain = account.email.split("@", 2)[1]

    begin
      result = Resolv::DNS.new(nameserver: SURBL_DNS_NAMESERVER).getaddress("#{domain}.multi.surbl.org").to_s
    rescue Resolv::ResolvError
      pop "domain not listed in SURBL"
    end

    last_octet = result.split(".").last.to_i
    if last_octet == 1
      Clog.emit("SURBL access blocked", {surbl_access_blocked: {account_ubid: account.ubid, domain:}})
      nap 60 * 60
    end

    matched_lists = SURBL_LISTS.filter_map { |name, bit| name if (last_octet & bit) > 0 }
    if matched_lists.any?
      Clog.emit("Account email domain listed in SURBL", {account_surbl_hit: {account_ubid: account.ubid, domain:, lists: matched_lists}})
      account.suspend
    end

    pop "domain check completed"
  end
end
