# frozen_string_literal: true

class Prog::ExpireProjectInvitations < Prog::Base
  label def wait
    ProjectInvitation.where { it.expires_at < Sequel::CURRENT_TIMESTAMP }.destroy

    nap 6 * 60 * 60
  end
end
