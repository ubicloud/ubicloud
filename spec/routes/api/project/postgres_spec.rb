# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  describe "unauthenticated" do
    it "not list" do
      get "/project/#{project.ubid}/pg"

      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
      postgres_project = Project.create(name: "default")
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    end

    it "success all vms" do
      Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-foo-1",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128
      )

      Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-foo-2",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128
      )

      get "/project/#{project.ubid}/postgres"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(2)
    end
  end
end
