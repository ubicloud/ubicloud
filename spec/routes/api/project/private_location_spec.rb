# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "private-location" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:project_wo_permissions) { project_with_default_policy(user, default_policy: nil) }

  let(:private_location) do
    loc = Location.create(
      name: "us-west-2",
      display_name: "aws-us-west-2",
      ui_name: "aws-us-west-2",
      visible: true,
      provider: "aws",
      project_id: project.id
    )
    LocationCredential.create(
      access_key: "access-key-id",
      secret_key: "secret-access-key"
    ) { it.id = loc.id }
    loc
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      [
        [:get, "/project/#{project.ubid}/private-location"],
        [:post, "/project/#{project.ubid}/private-location", {name: "region-1"}],
        [:delete, "/project/#{project.ubid}/private-location/#{private_location.ubid}"]
      ].each do |method, path, body|
        send(method, path, body)

        expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
      end
    end

    it "cannot create without login" do
      post "/project/#{project.ubid}/private-location", {
        name: "region-1",
        private_location_name: "us-west-2",
        aws_access_key: "access-key-id",
        aws_secret_key: "secret-access-key"
      }.to_json

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    describe "list" do
      it "success" do
        private_location
        get "/project/#{project.ubid}/private-location"

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["count"]).to eq(1)
      end

      it "invalid order column" do
        private_location
        get "/project/#{project.ubid}/private-location?order_column=ui_name"

        expect(last_response).to have_api_error(400, "Validation failed for following fields: order_column")
      end

      it "invalid id" do
        private_location
        get "/project/#{project.ubid}/private-location?start_after=invalid_id"

        expect(last_response).to have_api_error(400, "Validation failed for following fields: start_after")
      end
    end

    describe "create" do
      it "success" do
        post "/project/#{project.ubid}/private-location", {
          name: "hello",
          provider_location_name: "us-west-2",
          access_key: "access-key-id",
          secret_key: "secret-access-key"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["ui_name"]).to eq("hello")
        expect(JSON.parse(last_response.body)["name"]).to eq("us-west-2")
      end
    end

    describe "delete" do
      it "success" do
        reg = private_location
        delete "/project/#{project.ubid}/private-location/#{reg.ui_name}"

        expect(last_response.status).to eq(204)

        expect(Location.where(project_id: project.id).count).to eq(0)
        expect(LocationCredential.where(id: reg.id).count).to eq(0)
      end

      it "success with non-existing region" do
        delete "/project/#{project.ubid}/private-location/non-existing-region"

        expect(last_response.status).to eq(204)
      end

      it "can not delete aws region when it has resources" do
        reg = private_location
        expect(Config).to receive(:postgres_service_project_id).and_return(project.id).at_least(:once)
        Prog::Postgres::PostgresResourceNexus.assemble(
          project_id: project.id,
          name: "dummy-postgres",
          location_id: reg.id,
          target_vm_size: "standard-2",
          target_storage_size_gib: 118
        )

        delete "/project/#{project.ubid}/private-location/#{reg.ui_name}"

        expect(last_response).to have_api_error(409, "Private location '#{reg.ui_name}' has some resources, first, delete them.")
      end

      it "not authorized" do
        project_with_default_policy(user)
        p = create_account("test@test.com").create_project_with_default_policy("project-1")
        delete "/project/#{p.ubid}/private-location/#{private_location.ui_name}"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end
    end

    describe "show" do
      it "success" do
        get "/project/#{project.ubid}/private-location/#{private_location.ui_name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["ui_name"]).to eq(private_location.ui_name)
      end

      it "failure with unauthorized personal access token" do
        private_location
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create_with_id(project_id: project.id, subject_id: @pat.id, action_id: ActionType::NAME_MAP["Location:edit"])

        get "/project/#{project.ubid}/private-location/#{private_location.ui_name}"
        expect(last_response).to have_api_error(403, "Sorry, you don't have permission to continue with this request.")
      end

      it "not found" do
        private_location
        get "/project/#{project.ubid}/private-location/non-existing-region"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end

      it "not authorized" do
        private_location
        u = create_account("test@test.com")
        p = u.create_project_with_default_policy("project-1")
        get "/project/#{p.ubid}/private-location/#{private_location.ui_name}"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end
    end

    describe "update" do
      it "success" do
        post "/project/#{project.ubid}/private-location/#{private_location.ui_name}", {
          name: "hello"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["ui_name"]).to eq("hello")
      end
    end
  end
end
