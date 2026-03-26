# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "clickgres-billing" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }
  let(:billing_rate_id) { BillingRate.from_resource_properties("PostgresVCpu", "standard-m8gd", "us-west-2")["id"] }
  let(:storage_rate_id) { BillingRate.from_resource_properties("PostgresStorage", "standard", "us-west-2")["id"] }

  def create_billing_record(project_id:, billing_rate_id:, span:, resource_tags: Sequel.pg_jsonb({}))
    BillingRecord.create(
      project_id:,
      resource_id: SecureRandom.uuid,
      resource_name: "test-resource",
      billing_rate_id:,
      amount: 1,
      span: Sequel.pg_range(span),
      resource_tags:
    )
  end

  before do
    login_api
  end

  describe "GET /project/:project_id/clickgres-billing/postgres-resources" do
    it "requires start_time parameter" do
      expect {
        get "/project/#{project.ubid}/clickgres-billing/postgres-resources?end_time=#{Time.now.utc.iso8601}"
      }.to raise_error(Committee::InvalidRequest, /missing required parameters: start_time/)
    end

    it "requires end_time parameter" do
      expect {
        get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{(Time.now - 3600).utc.iso8601}"
      }.to raise_error(Committee::InvalidRequest, /missing required parameters: end_time/)
    end

    it "rejects invalid start_time" do
      expect {
        get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=not-a-date&end_time=#{Time.now.utc.iso8601}"
      }.to raise_error(Committee::InvalidRequest, /not conformant with date-time format/)
    end

    it "rejects end_time before start_time" do
      start_time = Time.now.utc.iso8601
      end_time = (Time.now - 3600).utc.iso8601
      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{start_time}&end_time=#{end_time}"
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "message")).to eq("end_time must be after start_time")
    end

    it "returns empty list when no records exist" do
      start_time = (Time.now - 3600).utc.iso8601
      end_time = Time.now.utc.iso8601
      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{start_time}&end_time=#{end_time}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"]).to eq([])
    end

    it "returns billing resources overlapping the time range" do
      t1 = Time.now - 3600
      t2 = Time.now
      create_billing_record(
        project_id: project.id,
        billing_rate_id:,
        span: t1..nil,
        resource_tags: Sequel.pg_jsonb({"chc_org_id" => "org-123"})
      )

      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{t1.utc.iso8601}&end_time=#{t2.utc.iso8601}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
      item = body["items"].first
      expect(item["resource_tags"]).to eq({"chc_org_id" => "org-123"})
    end

    it "filters by chc_org_id tag" do
      t1 = Time.now - 3600
      create_billing_record(
        project_id: project.id,
        billing_rate_id:,
        span: t1..nil,
        resource_tags: Sequel.pg_jsonb({"chc_org_id" => "org-123"})
      )
      create_billing_record(
        project_id: project.id,
        billing_rate_id:,
        span: t1..nil,
        resource_tags: Sequel.pg_jsonb({"chc_org_id" => "org-456"})
      )

      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{t1.utc.iso8601}&end_time=#{Time.now.utc.iso8601}&chc_org_id=org-123"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
      expect(body["items"].first["resource_tags"]["chc_org_id"]).to eq("org-123")
    end

    it "deduplicates by resource_id returning the most recent record" do
      t1 = Time.now - 7200
      t2 = Time.now - 3600
      t3 = Time.now
      resource_id = SecureRandom.uuid

      BillingRecord.create(
        project_id: project.id, resource_id:, resource_name: "test",
        billing_rate_id:,
        amount: 1, span: Sequel.pg_range(t1..t2),
        resource_tags: Sequel.pg_jsonb({"version" => "old"})
      )
      BillingRecord.create(
        project_id: project.id, resource_id:, resource_name: "test",
        billing_rate_id:,
        amount: 2, span: Sequel.pg_range(t2..t3),
        resource_tags: Sequel.pg_jsonb({"version" => "new"})
      )

      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{t1.utc.iso8601}&end_time=#{t3.utc.iso8601}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
      expect(body["items"].first["resource_tags"]).to eq({"version" => "new"})
    end

    it "collapses multiple billing types for the same resource into one row" do
      t1 = Time.now - 3600
      resource_id = SecureRandom.uuid
      BillingRecord.create(
        project_id: project.id, resource_id:, resource_name: "test",
        billing_rate_id:,
        amount: 1, span: Sequel.pg_range(t1..nil),
        resource_tags: Sequel.pg_jsonb({})
      )
      BillingRecord.create(
        project_id: project.id, resource_id:, resource_name: "test",
        billing_rate_id: storage_rate_id,
        amount: 64, span: Sequel.pg_range(t1..nil),
        resource_tags: Sequel.pg_jsonb({})
      )

      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{t1.utc.iso8601}&end_time=#{Time.now.utc.iso8601}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
    end

    it "excludes records with empty resource_tags (non-postgres resources)" do
      t1 = Time.now - 3600
      create_billing_record(project_id: project.id, billing_rate_id:, span: t1..nil)
      BillingRecord.create(
        project_id: project.id, resource_id: SecureRandom.uuid, resource_name: "vm-resource",
        billing_rate_id:, amount: 1, span: Sequel.pg_range(t1..nil),
        resource_tags: Sequel.pg_jsonb([])
      )

      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{t1.utc.iso8601}&end_time=#{Time.now.utc.iso8601}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
      expect(body["items"].first["resource_name"]).to eq("test-resource")
    end

    it "scopes to the project in the URL path" do
      t1 = Time.now - 3600
      create_billing_record(project_id: project.id, billing_rate_id:, span: t1..nil)

      other_project = Project.create(name: "other-project")
      create_billing_record(project_id: other_project.id, billing_rate_id:, span: t1..nil)

      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{t1.utc.iso8601}&end_time=#{Time.now.utc.iso8601}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
    end
  end
end
