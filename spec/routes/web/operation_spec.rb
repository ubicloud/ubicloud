# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "operation" do
  it "returns semaphore names matching a request_id" do
    st = Strand.create(prog: "Test", label: "start")
    req = SecureRandom.uuid
    Semaphore.incr(st.id, "initial_provisioning", req)
    Semaphore.incr(st.id, "configure", req)

    post "/operation", {id: req}

    expect(last_response.status).to eq 200
    expect(JSON.parse(last_response.body).sort).to eq ["configure", "initial_provisioning"]
  end

  it "returns empty array when no semaphores match" do
    post "/operation", {id: SecureRandom.uuid}

    expect(last_response.status).to eq 200
    expect(JSON.parse(last_response.body)).to eq []
  end
end
