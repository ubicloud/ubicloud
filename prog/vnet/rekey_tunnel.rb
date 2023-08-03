# frozen_string_literal: true

class Prog::Vnet::RekeyTunnel < Prog::Base
  subject_is :ipsec_tunnel

  def start

    hop :create_new_state
  end

  def create_new_state
    ipsec_tunnel.create_new_state
    hop :create_new_policy
  end

  def create_new_policy
    ipsec_tunnel.create_new_policy
    hop :delete_old_state
  end

  def delete_old_state
    ipsec_tunnel.delete_old_state
    hop :delete_old_policy
  end

  def delete_old_policy
    ipsec_tunnel.delete_old_policy
    pop "rekeyed tunnel"
  end
end
