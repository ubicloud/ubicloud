# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "InferenceEndpoint" do
  include AdminModelSpecHelper

  before do
    @instance = create_inference_endpoint
    admin_account_setup_and_login
  end

  it "displays the InferenceEndpoint instance page correctly" do
    click_link "InferenceEndpoint"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - InferenceEndpoint"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - InferenceEndpoint #{@instance.ubid}"
  end
end
