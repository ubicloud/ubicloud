# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "InferenceRouterTarget" do
  include AdminModelSpecHelper

  before do
    @instance = create_inference_router_target
    admin_account_setup_and_login
  end

  it "displays the InferenceRouterTarget instance page correctly" do
    click_link "InferenceRouterTarget"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - InferenceRouterTarget"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - InferenceRouterTarget #{@instance.ubid}"
  end
end
