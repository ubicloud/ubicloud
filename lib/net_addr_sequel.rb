# frozen_string_literal: true

module NetAddrSequel
  module DatasetMethods
    def literal_other_append(sql, value)
      case value
      when NetAddr::IPv4, NetAddr::IPv6
        literal_append(sql, value.to_s)
        sql << "::inet"
      when NetAddr::IPv4Net, NetAddr::IPv6Net
        literal_append(sql, value.to_s)
        sql << "::cidr"
      else
        super
      end
    end
  end

  module DatabaseMethods
    def schema_type_class(type)
      case type
      when :inet
        [NetAddr::IPv4, NetAddr::IPv6]
      when :cidr
        [NetAddr::IPv4Net, NetAddr::IPv6Net]
      else
        super
      end
    end

    private

    # :nocov:
    # Called when generating the schema caches, but not called at runtime, as
    # the values from the schema cache are used.
    def schema_column_type(db_type)
      case db_type
      when "inet"
        :inet
      when "cidr"
        :cidr
      else
        super
      end
    end
    # :nocov:

    def typecast_value_inet(value)
      case value
      when String
        begin
          NetAddr.parse_ip(value)
        rescue
          raise Sequel::InvalidValue, "invalid value for inet: #{value.inspect}"
        end
      when NetAddr::IPv4, NetAddr::IPv6
        value
      else
        raise Sequel::InvalidValue, "invalid value for inet: #{value.inspect}"
      end
    end

    def typecast_value_cidr(value)
      case value
      when String
        _typecast_value_cidr_string(value)
      when NetAddr::IPv4, NetAddr::IPv6
        _typecast_value_cidr_string(value.to_s)
      when NetAddr::IPv4Net, NetAddr::IPv6Net
        value
      else
        raise Sequel::InvalidValue, "invalid value for cidr: #{value.inspect}"
      end
    rescue NetAddr::ValidationError
      raise Sequel::InvalidValue, "invalid value for cidr: #{value.inspect}"
    end

    def _typecast_value_cidr_string(value)
      if value.include?(":") && !value.include?("/")
        # Work around NetAddr behavior of assuming /64 netmask for IPv6 addresses
        NetAddr.parse_net("#{value}/128")
      else
        NetAddr.parse_net(value)
      end
    end
  end
end
