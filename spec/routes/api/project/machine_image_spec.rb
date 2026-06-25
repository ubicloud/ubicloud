# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "project machine-image" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }
  let(:location_id) { Location[display_name: TEST_LOCATION].id }

  before { login_api }

  it "lists images across all locations" do
    create_machine_image_version_metal(project_id: project.id, location_id:)
    get "/project/#{project.ubid}/machine-image"
    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["count"]).to eq(1)
  end
end
