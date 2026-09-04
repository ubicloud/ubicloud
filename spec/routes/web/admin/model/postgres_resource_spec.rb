# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresResource" do
  include AdminModelSpecHelper

  before do
    @instance = create_postgres_resource(project: Project.create(name: "test-project"), location_id: Location::HETZNER_FSN1_ID)
    admin_account_setup_and_login
  end

  it "displays the PostgresResource instance page correctly" do
    @instance.update(cert_auth_users: Sequel.pg_jsonb_wrap(["user1", "user2"]))

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

  it "sets the target image family, driving convergence onto the new family" do
    click_link "PostgresResource"
    click_link @instance.admin_label
    click_link "Set image family"
    select "ubuntu-2604", from: "image_family"
    click_button "Set image family"
    expect(page).to have_flash_notice("Image family update scheduled")
    expect(@instance.reload.target_image_family).to eq "ubuntu-2604"
  end

  it "rejects an image family change for the lantern flavor" do
    @instance.update(flavor: "lantern")
    click_link "PostgresResource"
    click_link @instance.admin_label
    click_link "Set image family"
    select "ubuntu-2604", from: "image_family"
    dont_raise_admin_errors do
      click_button "Set image family"
      expect(page).to have_content "InvalidRequest: Lantern only has a ubuntu-2204 image"
    end
    expect(@instance.reload.target_image_family).to eq "ubuntu-2204"
  end

  it "rejects an image family change while a version upgrade is in progress" do
    create_postgres_server(resource: @instance).update(version: "16")
    @instance.update(target_version: "17")
    click_link "PostgresResource"
    click_link @instance.admin_label
    click_link "Set image family"
    select "ubuntu-2604", from: "image_family"
    dont_raise_admin_errors do
      click_button "Set image family"
      expect(page).to have_content "InvalidRequest: Cannot change image family while a version upgrade is in progress"
    end
    expect(@instance.reload.target_image_family).to eq "ubuntu-2204"
  end
end
