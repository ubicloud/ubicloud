# frozen_string_literal: true

require_relative "../model"

class GithubInstallation < Sequel::Model
  many_to_one :project
  one_to_many :runners, key: :installation_id, class: :GithubRunner

  include ResourceMethods

  def installation_url
    if type == "Organization"
      return "https://github.com/organizations/#{name}/settings/installations/#{installation_id}"
    end
    "https://github.com/settings/installations/#{installation_id}"
  end
end
