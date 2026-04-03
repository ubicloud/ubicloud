# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::ExpireProjectInvitations do
  subject(:epi) { described_class.new(Strand.new(prog: "ExpireProjectInvitations")) }

  describe "#wait" do
    it "expires project invitations that pass the expiration date" do
      project_id = Project.create(name: "test").id
      inviter_id = Account.create(email: "test@example.com").id
      ProjectInvitation.create(expires_at: Time.now - 10, email: "test1@example.com", project_id:, inviter_id:)
      not_expired = ProjectInvitation.create(expires_at: Time.now + 10, email: "test2@example.com", project_id:, inviter_id:)

      expect { epi.wait }.to nap(6 * 60 * 60)
      expect(ProjectInvitation.all).to contain_exactly(not_expired)
    end
  end
end
