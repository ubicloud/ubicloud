# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "InferenceRouter" do
  include AdminModelSpecHelper

  before do
    @instance = create_inference_router
    admin_account_setup_and_login
  end

  it "displays the InferenceRouter instance page correctly" do
    click_link "InferenceRouter"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - InferenceRouter"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - InferenceRouter #{@instance.ubid}"
  end
end
