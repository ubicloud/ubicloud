# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "api metrics labeling" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }

  def sample_count(handler:, code:, method: "GET")
    ApiMetrics.request_duration.get(labels: {handler:, method:, code:}).fetch("+Inf")
  end

  it "labels api requests with the matched openapi path template" do
    login_api
    project
    expect { get "/project/#{project.ubid}" }
      .to change { sample_count(handler: "/project/{project_id}", code: "200") }.by(1)
  end

  it "does not record requests that end before schema matching" do
    expect(ApiMetrics.request_duration).not_to receive(:observe)
    get "/project"
    expect(last_response.status).to eq 401
  end
end
