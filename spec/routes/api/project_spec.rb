# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  describe "unauthenticated" do
    it "not list" do
      get "/api/project"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end

    it "not create" do
      post "/api/project"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]).to eq("Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    describe "list" do
      it "success" do
        project
        get "/api/project"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body).length).to eq(2)
      end
    end

    describe "create" do
      it "success" do
        post "/api/project", {
          name: "test-project"
        }

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-project")
      end
    end

    describe "show" do
      it "success" do
        get "/api/project/#{project.ulid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(project.name)
      end

      it "not found" do
        get "/api/project/08s56d4kaj94xsmrnf5v5m3mav"

        expect(last_response.status).to eq(404)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Sorry, we couldn’t find the resource you’re looking for.")
      end
    end
  end
end
