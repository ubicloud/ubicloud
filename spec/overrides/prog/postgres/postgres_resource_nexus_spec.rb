# frozen_string_literal: true

require_relative "../../../prog/postgres/spec_helper"

RSpec.describe Prog::Postgres::PostgresResourceNexus::PrependMethods do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:nx) { Prog::Postgres::PostgresResourceNexus.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource) }
  let(:st) { postgres_resource.strand }
  let(:postgres_project) { Project.create(name: "postgres-service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:billing_rate_id) { BillingRate.from_resource_properties("PostgresVCpu", "standard-standard", "hetzner-fsn1", false)["id"] }

  let(:override_method) { described_class.instance_method(:create_billing_record) }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
  end

  describe "#create_billing_record" do
    it "populates billing record tags from resource tags and properties" do
      postgres_server
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "env", "value" => "prod"}]))

      override_method.bind_call(nx, billing_rate_id:, amount: 1)

      br = BillingRecord.where(resource_id: postgres_resource.id).first
      expect(br.resource_tags["env"]).to eq("prod")
      expect(br.resource_tags["cloud_provider"]).not_to be_nil
      expect(br.resource_tags["region"]).to eq(postgres_resource.location.name)
    end

    # The override is always prepended (OVERRIDE_DIR is set per test suite run, not individual test),
    # Therefore, need to call parent method explicitly to maintain coverage.
    # TODO: work with Ubicloud team to enable parent method tests to test parent method code,
    # even if override exists.
    it "overrides the base create_billing_record" do
      postgres_server
      base_method = nx.method(:create_billing_record).super_method
      expect(base_method).not_to be_nil
      base_method.call(billing_rate_id:, amount: 1)
      br = BillingRecord.where(resource_id: postgres_resource.id).first
      expect(br.resource_tags).to eq([])
    end
  end
end
