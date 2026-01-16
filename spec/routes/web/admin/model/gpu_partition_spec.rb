# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "GpuPartition" do
  include AdminModelSpecHelper

  before do
    @instance = create_gpu_partition
    admin_account_setup_and_login
  end

  it "displays the GpuPartition instance page correctly" do
    click_link "GpuPartition"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GpuPartition"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GpuPartition #{@instance.ubid}"
  end
end
