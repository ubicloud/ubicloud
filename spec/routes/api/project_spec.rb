# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  describe "unauthenticated" do
    it "not list" do
      get "/api/project"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not create" do
      post "/api/project"

      expect(last_response).to have_api_error(401, "Please login to continue")
    end

    it "not delete" do
      delete "api/project/#{project.ubid}"

      expect(last_response).to have_api_error(401, "Please login to continue")
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
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["count"]).to eq(2)
      end

      it "success with api subdomain" do
        project
        header "Host", "api.ubicloud.com"
        get "/project"

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["count"]).to eq(2)
      end

      it "invalid order column" do
        project
        get "/api/project?order_column=name"

        expect(last_response).to have_api_error(400, "Validation failed for following fields: order_column")
      end

      it "invalid id" do
        project
        get "/api/project?start_after=invalid_id"

        expect(last_response).to have_api_error(400, "Validation failed for following fields: start_after")
      end
    end

    describe "create" do
      it "success" do
        header "Content-Type", "application/json"
        post "/api/project", {
          name: "test-project"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-project")
      end

      it "missing parameter" do
        header "Content-Type", "application/json"
        post "/api/project", {}.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: body")
      end
    end

    describe "delete" do
      it "success" do
        delete "api/project/#{project.ubid}"

        expect(last_response.status).to eq(204)

        expect(Project[project.id].visible).to be_falsey
        expect(AccessTag.where(project_id: project.id).count).to eq(0)
        expect(AccessPolicy.where(project_id: project.id).count).to eq(0)
      end

      it "success with non-existing project" do
        delete "api/project/non_existing_id"

        expect(last_response.status).to eq(204)
      end

      it "can not delete project when it has resources" do
        Prog::Vm::Nexus.assemble("key", project.id, name: "vm1")

        delete "api/project/#{project.ubid}"

        expect(last_response).to have_api_error(409, "'#{project.name}' project has some resources. Delete all related resources first.")
      end

      it "not authorized" do
        u = create_account("test@test.com")
        p = u.create_project_with_default_policy("project-1")
        delete "api/project/#{p.ubid}"

        expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
      end
    end

    describe "show" do
      it "success" do
        get "/api/project/#{project.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(project.name)
      end

      it "not found" do
        get "/api/project/08s56d4kaj94xsmrnf5v5m3mav"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end

      it "not authorized" do
        u = create_account("test@test.com")
        p = u.create_project_with_default_policy("project-1")
        get "/api/project/#{p.ubid}"

        expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
      end
    end
  end
end
