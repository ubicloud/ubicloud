# frozen_string_literal: true

require_relative "../spec_helper"
RSpec.describe Clover, "postgres-location" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  describe "unauthenticated" do
    it "list" do
      get "/project/#{project.id}/postgres-location"
      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
      # postgres_project = Project.create(name: "default")
      # allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    end

    it "list" do
      get "/project/#{project.ubid}/postgres-location"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to include("items")
      expect(JSON.parse(last_response.body)["items"].length).to eq(3)
    end

    it "with aws vm sizes" do
      Location.create(name: "aws-region-1", provider: "aws", ui_name: "AWS", display_name: "display-aws-region-1", visible: true)
      get "/project/#{project.ubid}/postgres-location"
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
