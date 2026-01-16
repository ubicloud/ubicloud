# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "InferenceEndpointReplica" do
  include AdminModelSpecHelper

  before do
    @instance = create_inference_endpoint_replica
    admin_account_setup_and_login
  end

  it "displays the InferenceEndpointReplica instance page correctly" do
    click_link "InferenceEndpointReplica"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - InferenceEndpointReplica"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - InferenceEndpointReplica #{@instance.ubid}"
  end
end
