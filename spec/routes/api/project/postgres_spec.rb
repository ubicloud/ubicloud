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

    it "not list locations" do
      get "/project/#{project.ubid}/postgres/location"
      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
      postgres_project = Project.create(name: "default")
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    end

    it "success all postgres resources" do
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

    it "filters by single tag with key and value" do
      pg = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-production",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128
      ).subject
      pg.update(tags: [{key: "environment", value: "production"}])

      get "/project/#{project.ubid}/postgres?tags=environment:production"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].length).to eq(1)
      expect(body["items"][0]["name"]).to eq("pg-production")
    end

    it "pass empty tags filter and return all postgres resources" do
      pg = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-production",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128
      ).subject
      pg.update(tags: [{key: "environment", value: "production"}])

      get "/project/#{project.ubid}/postgres?tags="

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].length).to eq(1)
      expect(body["items"][0]["name"]).to eq("pg-production")
    end

    it "filters by multiple tags (AND logic)" do
      pg1 = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-prod-backend",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128
      ).subject
      pg1.update(tags: [{key: "environment", value: "production"}, {key: "team", value: "backend"}])

      pg2 = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-prod-frontend",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128
      ).subject
      pg2.update(tags: [{key: "environment", value: "production"}, {key: "team", value: "frontend"}])

      pg3 = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-staging-backend",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128
      ).subject
      pg3.update(tags: [{key: "environment", value: "staging"}, {key: "team", value: "backend"}])

      get "/project/#{project.ubid}/postgres?tags=environment:production,team:backend"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].length).to eq(1)
      expect(body["items"][0]["name"]).to eq("pg-prod-backend")
    end

    it "returns empty when no resources match tag filter" do
      pg = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-test",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128
      ).subject
      pg.update(tags: [{key: "environment", value: "development"}])

      get "/project/#{project.ubid}/postgres?tags=environment:production"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(0)
    end

    it "returns empty when resource doesn't have all required tags" do
      pg = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-test",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128
      ).subject
      pg.update(tags: [{key: "environment", value: "production"}, {key: "team", value: "frontend"}])

      # Requires both tags, but resource only has one
      get "/project/#{project.ubid}/postgres?tags=environment:production,team:backend"

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["items"].length).to eq(0)
    end

    it "handles mixed key:value filters" do
      pg1 = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-prod-backend",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128
      ).subject
      pg1.update(tags: [{key: "environment", value: "production"}, {key: "team", value: "backend"}])

      pg2 = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-staging-backend",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128
      ).subject
      pg2.update(tags: [{key: "environment", value: "staging"}, {key: "team", value: "backend"}])

      # Match environment production and team backend
      get "/project/#{project.ubid}/postgres?tags=environment:production,team:backend"

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].length).to eq(1)
      names = body["items"].map { |item| item["name"] }
      expect(names).to eq(["pg-prod-backend"])
    end

    it "returns error when tags are in invalid format" do
      get "/project/#{project.ubid}/postgres?tags=environment,team:backend"

      expect(last_response).to have_api_error(400, "Validation failed for following fields: tags")
    end

    it "lists locations" do
      get "/project/#{project.ubid}/postgres/locations"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to include("items")
      expect(JSON.parse(last_response.body)["items"].length).to eq(3)
    end

    it "lists locations with aws vm sizes" do
      Location.create(name: "aws-region-1", provider: "aws", ui_name: "AWS", display_name: "display-aws-region-1", visible: true)
      get "/project/#{project.ubid}/postgres/locations"
      expect(last_response.status).to eq(200)
      response = JSON.parse(last_response.body)["items"]
      expect(response.length).to eq(4)

      expect(response).to include(hash_including("name" => "hetzner-fsn1"))
      expect(response).to include(hash_including("name" => "hetzner-hel1"))
      expect(response).to include(hash_including("name" => "leaseweb-wdc02"))
      expect(response).to include(hash_including(
        "name" => "aws-region-1",
        "display_name" => "display-aws-region-1",
        "ui_name" => "AWS",
        "provider" => "aws",
        "visible" => true,
        "available_vm_families" => be_an_instance_of(Array),
        "available_postgres_versions" => be_an_instance_of(Array)
      ))
      aws = response.find { |loc| loc["name"] == "aws-region-1" }
      aws_families = aws["available_vm_families"]
      expect(aws_families.find { |f| f["name"] == "m8gd" }).to match hash_including(
        "name" => "m8gd",
        "display_name" => "General Purpose, Graviton3",
        "category" => "general-purpose",
        "sizes" => be_an_instance_of(Array)
      )
      expect(aws_families.find { |f| f["name"] == "i8g" }).to match hash_including(
        "name" => "i8g",
        "display_name" => "Storage Optimized, Graviton4",
        "category" => "storage-optimized",
        "sizes" => be_an_instance_of(Array)
      )
      family_names = aws_families.map { |f| f["name"] }
      expect(family_names).to eq(family_names.uniq)
      expect(aws["available_postgres_versions"]).to contain_exactly("18", "17", "16")
    end
  end
end
