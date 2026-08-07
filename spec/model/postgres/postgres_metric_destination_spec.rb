# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresMetricDestination do
  subject(:metric_destination) { described_class.create(postgres_resource: resource, url: "https://md.example.com", **auth) }

  let(:project) { Project.create(name: "postgres-metric-destination") }
  let(:location) { Location[name: "hetzner-fsn1"] }
  let(:resource) { create_postgres_resource(project:, location_id: location.id) }

  context "with basic auth" do
    let(:auth) { {username: "md-user", password: "md-pass"} }

    it "reports the basic_auth section" do
      expect(metric_destination.auth_methods).to eq(["basic_auth"])
    end

    it "encrypts the password" do
      expect(metric_destination.password).to eq("md-pass")
      expect(described_class.dataset.where(id: metric_destination.id).get(:password)).not_to eq("md-pass")
    end
  end

  context "with options" do
    let(:auth) { {options: {"authorization" => {"type" => "Bearer", "credentials" => "my_token"}, "headers" => {"X-Scope-OrgID" => "tenant1"}}} }

    it "reports the option sections in the order prometheus applies them" do
      expect(metric_destination.auth_methods).to eq(["authorization", "headers"])
    end

    it "round trips options as json and encrypts them" do
      expect(described_class[metric_destination.id].options).to eq(auth[:options])
      expect(described_class.dataset.where(id: metric_destination.id).get(:options)).not_to include("my_token")
    end
  end

  context "with basic auth and headers" do
    let(:auth) { {username: "md-user", password: "md-pass", options: {"headers" => {"X-Scope-OrgID" => "tenant1"}}} }

    it "reports both sections" do
      expect(metric_destination.auth_methods).to eq(["basic_auth", "headers"])
    end
  end
end
