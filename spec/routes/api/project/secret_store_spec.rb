# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "secret store" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }
  let(:secret_store) { SecretStore.create(project_id: project.id, name: "my-store") }

  describe "unauthenticated" do
    it "cannot list" do
      get "/project/#{project.ubid}/secret-store"
      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end

    it "cannot create" do
      post "/project/#{project.ubid}/secret-store"
      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before { login_api }

    it "lists secret stores" do
      get "/project/#{project.ubid}/secret-store"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("items" => [])

      secret_store
      get "/project/#{project.ubid}/secret-store"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].map { it["name"] }).to eq(["my-store"])
    end

    it "creates a secret store" do
      post "/project/#{project.ubid}/secret-store", {name: "store-1", description: "prod secrets"}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["name"]).to eq("store-1")
      expect(body["description"]).to eq("prod secrets")
      expect(SecretStore.first(name: "store-1")).not_to be_nil
    end

    it "returns a validation error for invalid names" do
      post "/project/#{project.ubid}/secret-store", {name: "Bad Name"}.to_json
      expect(last_response.status).to eq(400)
    end

    it "gets a secret store with its keys, by id and by name" do
      Secret.create(secret_store_id: secret_store.id, key: "k1", value: "v1")

      get "/project/#{project.ubid}/secret-store/#{secret_store.ubid}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["name"]).to eq("my-store")
      expect(body["secrets"]).to eq([{"key" => "k1"}])

      get "/project/#{project.ubid}/secret-store/my-store"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["id"]).to eq(secret_store.ubid)
    end

    it "renames a secret store" do
      post "/project/#{project.ubid}/secret-store/#{secret_store.ubid}", {name: "renamed"}.to_json
      expect(last_response.status).to eq(200)
      expect(secret_store.reload.name).to eq("renamed")
    end

    it "updates the description without renaming" do
      post "/project/#{project.ubid}/secret-store/#{secret_store.ubid}", {description: "updated"}.to_json
      expect(last_response.status).to eq(200)
      secret_store.reload
      expect(secret_store.name).to eq("my-store")
      expect(secret_store.description).to eq("updated")
    end

    it "deletes a secret store" do
      delete "/project/#{project.ubid}/secret-store/#{secret_store.ubid}"
      expect(last_response.status).to eq(204)
      expect(SecretStore[secret_store.id]).to be_nil
    end

    it "returns 404 for a missing secret store" do
      get "/project/#{project.ubid}/secret-store/#{SecretStore.generate_ubid}"
      expect(last_response.status).to eq(404)
    end

    describe "secrets" do
      it "sets, gets, lists, updates and deletes a secret" do
        post "/project/#{project.ubid}/secret-store/#{secret_store.ubid}/secret", {key: "db-pass", value: "p@ss"}.to_json
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to eq("key" => "db-pass", "value" => "p@ss")

        get "/project/#{project.ubid}/secret-store/#{secret_store.ubid}/secret/db-pass"
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to eq("key" => "db-pass", "value" => "p@ss")

        get "/project/#{project.ubid}/secret-store/#{secret_store.ubid}/secret"
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to eq("items" => [{"key" => "db-pass"}])

        # Re-setting the same key updates in place rather than creating a duplicate.
        post "/project/#{project.ubid}/secret-store/#{secret_store.ubid}/secret", {key: "db-pass", value: "rotated"}.to_json
        expect(last_response.status).to eq(200)
        expect(Secret.where(secret_store_id: secret_store.id, key: "db-pass").count).to eq(1)

        get "/project/#{project.ubid}/secret-store/#{secret_store.ubid}/secret/db-pass"
        expect(JSON.parse(last_response.body)["value"]).to eq("rotated")

        delete "/project/#{project.ubid}/secret-store/#{secret_store.ubid}/secret/db-pass"
        expect(last_response.status).to eq(204)

        get "/project/#{project.ubid}/secret-store/#{secret_store.ubid}/secret/db-pass"
        expect(last_response.status).to eq(404)
      end

      it "returns 404 for a missing key" do
        get "/project/#{project.ubid}/secret-store/#{secret_store.ubid}/secret/nope"
        expect(last_response.status).to eq(404)
      end
    end

    describe "authorization" do
      it "denies access to a subject without any permission" do
        secret_store
        AccessControlEntry.dataset.destroy

        get "/project/#{project.ubid}/secret-store/#{secret_store.ubid}"
        expect(last_response.status).to eq(403)
      end

      it "allows view but not edit when granted only SecretStore:view" do
        secret_store
        admin_tag = SubjectTag.first(project_id: project.id, name: "Admin")
        AccessControlEntry.dataset.destroy
        AccessControlEntry.create(project_id: project.id, subject_id: admin_tag.id, object_id: secret_store.id, action_id: ActionType::NAME_MAP["SecretStore:view"])

        get "/project/#{project.ubid}/secret-store/#{secret_store.ubid}"
        expect(last_response.status).to eq(200)

        post "/project/#{project.ubid}/secret-store/#{secret_store.ubid}/secret", {key: "k", value: "v"}.to_json
        expect(last_response.status).to eq(403)
      end

      it "excludes stores the subject cannot view from the list" do
        secret_store
        AccessControlEntry.dataset.destroy

        get "/project/#{project.ubid}/secret-store"
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)).to eq("items" => [])
      end
    end
  end
end
