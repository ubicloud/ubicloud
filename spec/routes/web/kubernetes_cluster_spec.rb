# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "Kubernetes" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  describe "authenticated" do
    before do
      login(user.email)
    end

    describe "feature disabled" do
      it "is not shown in the sidebar" do
        visit project.path
        expect(page).to have_no_content("Kubernetes")

        project.set_ff_kubernetes true

        visit project.path
        expect(page).to have_content("Kubernetes")
      end
    end
  end
end
