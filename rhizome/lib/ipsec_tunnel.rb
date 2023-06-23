# frozen_string_literal: true

require_relative "common"
require "netaddr"

class IPSecTunnel
  def initialize(namespace, src_clover_ephemeral, dst_clover_ephemeral, src_private_subnet, dst_private_subnet, src_private_subnet4, dst_private_subnet4, spi, spi4, security_key, direction)
    @namespace = namespace
    @src_clover_ephemeral = src_clover_ephemeral
    @dst_clover_ephemeral = dst_clover_ephemeral
    @src_private_subnet = src_private_subnet
    @dst_private_subnet = dst_private_subnet
    @src_private_subnet4 = src_private_subnet4
    @dst_private_subnet4 = dst_private_subnet4
    @spi = spi
    @spi4 = spi4
    @security_key = security_key
    @direction = direction
  end

  def setup
    # first delete any existing state & policy for idempotency
    r(delete_state_command)
    r(delete_policy_command)
    r(delete_state_command4)
    r(delete_policy_command4)
    r(add_state_command)
    r(add_state_command4)
    r(add_policy_command)
    r(add_policy_command4)
  end

  def delete_state_command
    p "ip -n #{@namespace} xfrm state deleteall " \
        "src #{@src_clover_ephemeral} " \
        "dst #{@dst_clover_ephemeral}"
  end

  def delete_state_command4
    p "ip -n #{@namespace} xfrm state deleteall " \
        "src #{@src_private_subnet4} " \
        "dst #{@dst_private_subnet4}"
  end

  def delete_policy_command
    p "ip -n #{@namespace} xfrm policy deleteall " \
        "src #{@src_private_subnet} " \
        "dst #{@dst_private_subnet} " \
        "dir #{@direction}"
  end

  def delete_policy_command4
    p "ip -n #{@namespace} xfrm policy deleteall " \
        "src #{@src_private_subnet4} " \
        "dst #{@dst_private_subnet4} " \
        "dir #{@direction}"
  end

  def add_state_command
    p "ip -n #{@namespace} xfrm state add " \
      "src #{@src_clover_ephemeral} " \
      "dst #{@dst_clover_ephemeral} " \
      "proto esp " \
      "spi #{@spi} reqid 1 mode tunnel " \
      "aead 'rfc4106(gcm(aes))' #{@security_key.shellescape} 128"
  end

  def add_state_command4
    p "ip -n #{@namespace} xfrm state add " \
      "src #{@src_clover_ephemeral} " \
      "dst #{@dst_clover_ephemeral} " \
      "proto esp " \
      "spi #{@spi4} reqid 1 mode tunnel " \
      "aead 'rfc4106(gcm(aes))' #{@security_key.shellescape} 128 " \
      "sel src 0.0.0.0/0 dst 0.0.0.0/0"
  end

  def add_policy_command
    p "ip -n #{@namespace} xfrm policy add " \
      "src #{@src_private_subnet} " \
      "dst #{@dst_private_subnet} dir #{@direction} " \
      "tmpl src #{@src_clover_ephemeral} " \
      "dst #{@dst_clover_ephemeral} " \
      "spi #{@spi} proto esp reqid 1 " \
      "mode tunnel"
  end

  def add_policy_command4
    p "ip -n #{@namespace} xfrm policy add " \
      "src #{@src_private_subnet4} " \
      "dst #{@dst_private_subnet4} dir #{@direction} " \
      "tmpl src #{@src_clover_ephemeral} " \
      "dst #{@dst_clover_ephemeral} " \
      "spi #{@spi4} proto esp reqid 1 " \
      "mode tunnel"
  end
end
