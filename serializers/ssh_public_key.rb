# frozen_string_literal: true

class Serializers::SshPublicKey < Serializers::Base
  def self.serialize_internal(ssh_public_key, options = {})
    h = {
      id: ssh_public_key.ubid,
      name: ssh_public_key.name
    }

    h[:public_key] = ssh_public_key.public_key if options[:detailed]

    h
  end
end
