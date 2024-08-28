# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::ExpireProjectInvitations do
  subject(:epi) { described_class.new(Strand.new(prog: "ExpireProjectInvitations")) }

  describe "#wait" do
    it "expires project invitations that pass the expiration date" do
      ProjectInvitation.create(expires_at: Time.now - 10, email: "test1@example.com", project_id: "8d8dc04b-c718-86d2-b75c-634d8091e448", inviter_id: "bd3479c6-5ee3-894c-8694-5190b76f84cf")
      not_expired = ProjectInvitation.create(expires_at: Time.now + 10, email: "test2@example.com", project_id: "8d8dc04b-c718-86d2-b75c-634d8091e448", inviter_id: "bd3479c6-5ee3-894c-8694-5190b76f84cf")

      expect { epi.wait }.to nap(6 * 60 * 60)
      expect(ProjectInvitation.all).to contain_exactly(not_expired)
    end
  end
end
