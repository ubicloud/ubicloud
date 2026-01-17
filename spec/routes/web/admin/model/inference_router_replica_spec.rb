# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "InferenceRouterReplica" do
  include AdminModelSpecHelper

  before do
    @instance = create_inference_router_replica
    admin_account_setup_and_login
  end

  it "displays the InferenceRouterReplica instance page correctly" do
    click_link "InferenceRouterReplica"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - InferenceRouterReplica"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - InferenceRouterReplica #{@instance.ubid}"
  end
end
