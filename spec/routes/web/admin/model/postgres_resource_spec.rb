# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresResource" do
  include AdminModelSpecHelper

  before do
    @instance = create_postgres_resource
    admin_account_setup_and_login
  end

  it "displays the PostgresResource instance page correctly" do
    click_link "PostgresResource"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresResource - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresResource #{@instance.ubid}"

    expect(page.all("a").any? { |a| a.text == "View in Clover" }).to be(false)
  end

  it "links to clover when configured to" do
    allow(Config).to receive(:clover_admin_links_to_clover).and_return(true)

    click_link "PostgresResource"
    expect(page.status_code).to eq 200

    click_link @instance.admin_label
    expect(page.status_code).to eq 200

    link = page.all("a").find { |a| a.text == "View in Clover" }
    expect(link).not_to be_nil
    expect(link["href"]).to eq "http://localhost:9292/project/#{@instance.project.ubid}/location/#{@instance.location.display_name}/postgres/#{@instance.name}/overview"
  end
end
