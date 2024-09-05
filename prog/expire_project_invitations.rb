# frozen_string_literal: true

class Prog::ExpireProjectInvitations < Prog::Base
  label def wait
    ProjectInvitation.where { _1.expires_at < Time.now }.all.each(&:destroy)

    nap 6 * 60 * 60
  end
end
