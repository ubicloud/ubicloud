# frozen_string_literal: true

require "resolv"

module DnsChecker
  IN = Resolv::DNS::Resource::IN

  TYPE_MAP = {
    A: IN::A,
    AAAA: IN::AAAA,
    CNAME: IN::CNAME,
  }.freeze

  def self.open(nameservers)
    Resolv::DNS.open(nameserver: nameservers, search: [].freeze, ndots: 1) do
      it.timeouts = [1, 2, 3].freeze
      checker = Checker.new(it)
      yield checker
      return checker.failures
    end
  end

  class Checker
    attr_reader :failures

    def initialize(resolver)
      @resolver = resolver
      @failures = []
    end

    def check(type, record_name, expected_value)
      typeclass = TYPE_MAP.fetch(type)
      resource = @resolver.getresource(record_name, typeclass)
      if type == :CNAME
        name = resource.name
        actual_value = name.to_s
        actual_value += "." if name.absolute?
      else
        actual_value = resource.address.to_s
      end
    rescue Resolv::ResolvError => e
      # Deliberately avoid Util.exception_to_hash here, as backtrace is not helpful
      @failures << {type:, record_name:, expected_value:, exception: "#{e.class}: #{e.message}"}
    else
      unless expected_value == actual_value
        @failures << {type:, record_name:, expected_value:, actual_value:}
      end
    end
  end
end
