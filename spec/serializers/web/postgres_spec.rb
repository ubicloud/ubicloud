# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Serializers::Web::Postgres do
  let(:pg) { PostgresResource.new(server_name: "pg-server-name").tap { _1.id = "69c0f4cd-99c1-8ed0-acfe-7b013ce2fa0b" } }

  it "can serialize when no earliest/latest restore times" do
    expect(pg).to receive(:strand).and_return(instance_double(Strand, label: "start")).twice
    expect(pg).to receive(:timeline).and_return(instance_double(PostgresTimeline, earliest_restore_time: nil, latest_restore_time: nil)).exactly(3)
    expect(pg).to receive(:server).and_return(instance_double(PostgresServer, primary?: true, vm: nil)).exactly(3)
    data = described_class.new(:detailed).serialize(pg)
    expect(data[:earliest_restore_time]).to be_nil
    expect(data[:latest_restore_time]).to be_nil
  end

  it "can serialize when have earliest/latest restore times" do
    time = Time.now
    expect(pg).to receive(:strand).and_return(instance_double(Strand, label: "start")).twice
    expect(pg).to receive(:timeline).and_return(instance_double(PostgresTimeline, earliest_restore_time: time, latest_restore_time: time)).exactly(3)
    expect(pg).to receive(:server).and_return(instance_double(PostgresServer, primary?: true, vm: nil)).exactly(3)
    data = described_class.new(:detailed).serialize(pg)
    expect(data[:earliest_restore_time]).to eq(time.iso8601)
    expect(data[:latest_restore_time]).to eq(time.iso8601)
  end

  it "can serialize when not primary" do
    expect(pg).to receive(:strand).and_return(instance_double(Strand, label: "start")).twice
    expect(pg).to receive(:server).and_return(instance_double(PostgresServer, primary?: false, vm: nil))
    data = described_class.new(:detailed).serialize(pg)
    expect(data[:earliest_restore_time]).to be_nil
    expect(data[:latest_restore_time]).to be_nil
  end
end
