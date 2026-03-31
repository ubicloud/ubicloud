# frozen_string_literal: true

require_relative "../spec_helper"
RSpec.describe Clover, "postgres/capabilities" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  describe "unauthenticated" do
    it "requires auth" do
      get "/project/#{project.id}/postgres/capabilities"
      expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    it "returns option tree and metadata" do
      get "/project/#{project.ubid}/postgres/capabilities"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body).to include("option_tree", "metadata")
      expect(body["option_tree"]).to include("flavor")
      expect(body["metadata"]).to include("flavor", "location", "family", "size", "ha_type")
    end

    it "encodes location dependency chain in the tree" do
      get "/project/#{project.ubid}/postgres/capabilities"
      body = JSON.parse(last_response.body)
      tree = body["option_tree"]

      standard = tree.dig("flavor", "standard")
      expect(standard).to include("location", "version")

      locations = standard["location"]
      expect(locations.keys).to include("hetzner-fsn1")

      families = locations["hetzner-fsn1"]["family"]
      expect(families).to include("standard", "hobby")
    end

    it "includes size and storage_size levels" do
      get "/project/#{project.ubid}/postgres/capabilities"
      body = JSON.parse(last_response.body)
      tree = body["option_tree"]

      family_tree = tree.dig("flavor", "standard", "location", "hetzner-fsn1", "family", "standard")
      expect(family_tree).to include("size")

      size_key = family_tree["size"].keys.first
      expect(family_tree["size"][size_key]).to include("storage_size")
    end

    it "includes ha_type as leaf" do
      get "/project/#{project.ubid}/postgres/capabilities"
      body = JSON.parse(last_response.body)
      tree = body["option_tree"]

      family_tree = tree.dig("flavor", "standard", "location", "hetzner-fsn1", "family", "standard")
      size_key = family_tree["size"].keys.first
      storage_key = family_tree["size"][size_key]["storage_size"].keys.first
      ha_types = family_tree["size"][size_key]["storage_size"][storage_key]["ha_type"]
      expect(ha_types).to include("none", "async", "sync")
    end

    it "includes version metadata" do
      get "/project/#{project.ubid}/postgres/capabilities"
      body = JSON.parse(last_response.body)
      versions = body.dig("option_tree", "flavor", "standard", "version")
      expect(versions.keys).to include("16", "17", "18")
    end

    it "populates metadata for all option types" do
      get "/project/#{project.ubid}/postgres/capabilities"
      body = JSON.parse(last_response.body)
      metadata = body["metadata"]

      expect(metadata.dig("flavor", "standard", "display_name")).to eq("PostgreSQL Database")
      expect(metadata.dig("location", "hetzner-fsn1", "provider")).to eq("hetzner")
      expect(metadata.dig("family", "standard", "display_name")).to eq("Dedicated CPU")
      expect(metadata.dig("ha_type", "none", "standby_count")).to eq(0)
    end

    it "filters aws sizes by instance availability" do
      get "/project/#{project.ubid}/postgres/capabilities"
      body = JSON.parse(last_response.body)
      tree = body["option_tree"]

      aws_location = tree.dig("flavor", "standard", "location").keys.find { |l|
        Location[name: l]&.provider == "aws"
      }
      next unless aws_location

      families = tree.dig("flavor", "standard", "location", aws_location, "family")
      expect(families).to include("m8gd")

      m8gd_sizes = families["m8gd"]["size"].keys
      expect(m8gd_sizes).to include("m8gd.large")
      expect(m8gd_sizes).not_to include("m8gd.metal-24xl")
    end

    it "does not filter non-aws locations" do
      get "/project/#{project.ubid}/postgres/capabilities"
      body = JSON.parse(last_response.body)
      families = body.dig("option_tree", "flavor", "standard", "location", "hetzner-fsn1", "family")
      expect(families.keys).to include("standard", "hobby")
    end
  end
end
