# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PostgresGateway do
  let(:gateway) {
    described_class.create(location_id: Location::HETZNER_FSN1_ID, hostname_suffix: "ember.test")
  }

  it "generates gw-prefixed ubids" do
    expect(described_class.generate_ubid.to_s).to start_with("gw")
  end

  it "builds an ember's hostname from its own suffix" do
    ember = create_postgres_ember
    expect(gateway.hostname_for(ember)).to eq("#{ember.ubid}.ember.test")
  end
end
