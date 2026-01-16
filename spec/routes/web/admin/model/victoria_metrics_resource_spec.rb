# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "VictoriaMetricsResource" do
  include AdminModelSpecHelper

  before do
    @instance = create_victoria_metrics_resource
    admin_account_setup_and_login
  end

  it "displays the VictoriaMetricsResource instance page correctly" do
    click_link "VictoriaMetricsResource"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VictoriaMetricsResource"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - VictoriaMetricsResource #{@instance.ubid}"
  end
end
