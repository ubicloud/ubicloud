# frozen_string_literal: true

require_relative "common"
require_relative "vm_path"
require "netaddr"

IPSecTunnelEndpoint = Struct.new(:vm_name, :ephemeral_net6, :private_subnet) do
  def clover_ephemeral
    vp = VmPath.new(vm_name)
    subnet = NetAddr::IPv6Net.parse(vp.read_clover_ephemeral)
    subnet.network.to_s
  end

  def q_clover_ephemeral
    @q_clover_ephemeral ||= clover_ephemeral.shellescape
  end

  def q_private_subnet
    private_subnet.shellescape
  end
end

class IPSecTunnel
  def initialize(from_endpoint, to_endpoint, spi, security_key)
    @from_endpoint = from_endpoint
    @to_endpoint = to_endpoint
    @security_key = security_key
    @spi = spi
  end

  def setup_src
    namespace = @from_endpoint.vm_name
    # first delete any existing state & policy for idempotency
    r(delete_state_command(namespace))
    r(delete_policy_command(namespace, "out"))
    r(add_state_command(namespace))
    r(add_policy_command(namespace, "out"))
  end

  def setup_dst
    namespace = @to_endpoint.vm_name
    # first delete any existing state & policy for idempotency
    r(delete_state_command(namespace))
    r(delete_policy_command(namespace, "fwd"))
    r(add_state_command(namespace))
    r(add_policy_command(namespace, "fwd"))
  end

  def delete_state_command(namespace)
    p "ip -n #{namespace.shellescape} xfrm state deleteall " \
        "src #{@from_endpoint.q_clover_ephemeral} " \
        "dst #{@to_endpoint.q_clover_ephemeral}"
  end

  def delete_policy_command(namespace, direction)
    p "ip -n #{namespace.shellescape} xfrm policy deleteall " \
        "src #{@from_endpoint.q_private_subnet} " \
        "dst #{@to_endpoint.q_private_subnet} " \
        "dir #{direction}"
  end

  def add_state_command(namespace)
    p "ip -n #{namespace.shellescape} xfrm state add " \
      "src #{@from_endpoint.q_clover_ephemeral} " \
      "dst #{@to_endpoint.q_clover_ephemeral} " \
      "proto esp " \
      "spi #{@spi} reqid 1 mode tunnel " \
      "aead 'rfc4106(gcm(aes))' #{@security_key.shellescape} 128"
  end

  def add_policy_command(namespace, direction)
    p "ip -n #{namespace.shellescape} xfrm policy add " \
      "src #{@from_endpoint.q_private_subnet} " \
      "dst #{@to_endpoint.q_private_subnet} dir #{direction} " \
      "tmpl src #{@from_endpoint.q_clover_ephemeral} " \
      "dst #{@to_endpoint.q_clover_ephemeral} " \
      "spi #{@spi} proto esp reqid 1 " \
      "mode tunnel"
  end
end
