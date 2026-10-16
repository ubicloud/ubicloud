# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Cert" do
  include AdminModelSpecHelper

  before do
    @instance = create_cert
    admin_account_setup_and_login
  end

  it "displays the Cert instance page correctly" do
    click_link "Cert"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Cert"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Cert #{@instance.ubid}"
  end

  it "can restart the ACME order of a Cert" do
    Strand.create_with_id(@instance, prog: "Vnet::CertNexus", label: "wait_dns_validation")
    visit "/model/Cert/#{@instance.ubid}"
    click_link "Restart ACME Order"
    click_button "Restart ACME Order"

    expect(page).to have_content("Restart scheduled for Cert")
    expect(Semaphore.where(strand_id: @instance.id, name: "restarted").count).to eq 1
  end

  it "does not show the restart action when the Cert is not waiting on an ACME order" do
    Strand.create_with_id(@instance, prog: "Vnet::CertNexus", label: "wait")
    visit "/model/Cert/#{@instance.ubid}"
    expect(page).to have_no_link "Restart ACME Order"
  end
end
