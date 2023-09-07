# frozen_string_literal: true

class Serializers::Web::GithubInstallation < Serializers::Base
  def self.base(ins)
    {
      id: ins.id,
      name: ins.name,
      type: ins.type,
      installation_id: ins.installation_id,
      installation_url: ins.installation_url
    }
  end

  structure(:default) do |ins|
    base(ins)
  end
end
