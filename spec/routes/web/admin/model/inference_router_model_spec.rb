# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "InferenceRouterModel" do
  include AdminModelSpecHelper

  before do
    @instance = create_inference_router_model
    admin_account_setup_and_login
  end

  it "displays the InferenceRouterModel instance page correctly" do
    click_link "InferenceRouterModel"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - InferenceRouterModel"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - InferenceRouterModel #{@instance.ubid}"
  end
end
