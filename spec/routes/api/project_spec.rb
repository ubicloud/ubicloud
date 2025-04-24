# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "project" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      [
        [:get, "/project"],
        [:post, "/project", {name: "p-1"}],
        [:delete, "/project/#{project.ubid}"]
      ].each do |method, path, body|
        send(method, path, body)

        expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
      end
    end

    it "does not recognize invalid personal access tokens" do
      account = Account[email: user.email]
      pat = ApiKey.create_with_id(owner_table: "accounts", owner_id: account.id, used_for: "api", project_id: project.id)

      header "Authorization", "Bearer pat-#{pat.ubid[0...-1]}-#{pat.key}"
      get "/project"
      expect(last_response.status).to eq(401)

      header "Authorization", "Bearer pat-#{pat.ubid}-#{pat.key[0...-1]}"
      get "/project"
      expect(last_response.status).to eq(401)

      header "Authorization", "Bearer pat-#{account.ubid}-#{pat.key}"
      get "/project"
      expect(last_response.status).to eq(401)

      pat.update(is_valid: false)
      header "Authorization", "Bearer pat-#{pat.ubid}-#{pat.key}"
      get "/project"
      expect(last_response.status).to eq(401)
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    describe "list" do
      it "success" do
        project
        get "/project"

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["count"]).to eq(2)
      end

      it "invalid order column" do
        project
        get "/project?order_column=name"

        expect(last_response).to have_api_error(400, "Validation failed for following fields: order_column")
      end

      it "invalid id" do
        project
        get "/project?start_after=invalid_id"

        expect(last_response).to have_api_error(400, "Validation failed for following fields: start_after")
      end
    end

    describe "create" do
      it "success" do
        project
        post "/project", {
          name: "test-project"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-project")
      end
    end

    describe "delete" do
      it "success" do
        delete "/project/#{project.ubid}"

        expect(last_response.status).to eq(204)

        expect(Project[project.id].visible).to be_falsey
        expect(DB[:access_tag].where(project_id: project.id).count).to eq(0)
        expect(SubjectTag.where(project_id: project.id).count).to eq(0)
        expect(AccessControlEntry.where(project_id: project.id).count).to eq(0)
      end

      it "success with non-existing project" do
        project_with_default_policy(user)
        delete "/project/pj000000000000000000000000"

        expect(last_response.status).to eq(204)
      end

      it "can not delete project when it has resources" do
        Prog::Vm::Nexus.assemble("k y", project.id, name: "vm1")

        delete "/project/#{project.ubid}"

        expect(last_response).to have_api_error(409, "'#{project.name}' project has some resources. Delete all related resources first.")
      end

      it "not authorized" do
        project_with_default_policy(user)
        p = create_account("test@test.com").create_project_with_default_policy("project-1")
        delete "/project/#{p.ubid}"

        expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
      end
    end

    describe "show" do
      it "success" do
        get "/project/#{project.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(project.name)
      end

      it "failure with unauthorized personal access token" do
        project
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create_with_id(project_id: project.id, subject_id: @pat.id, action_id: ActionType::NAME_MAP["Project:edit"])

        get "/project/#{project.ubid}"
        expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
      end

      it "not found" do
        project
        get "/project/pj000000000000000000000000"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end

      it "not authorized" do
        project
        u = create_account("test@test.com")
        p = u.create_project_with_default_policy("project-1")
        get "/project/#{p.ubid}"

        expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
      end
    end
  end
end
