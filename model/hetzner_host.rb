# frozen_string_literal: true

require_relative "../model"

class HetznerHost < Sequel::Model
  one_to_one :vm_host, key: :id

  PROVIDER_NAME = "hetzner"

  def api
    @api ||= Hosting::HetznerApis.new(self)
  end

  def connection_string
    Config.hetzner_connection_string
  end

  def user
    Config.hetzner_user
  end

  def password
    Config.hetzner_password
  end
end
