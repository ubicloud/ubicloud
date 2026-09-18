# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin do
  let(:image_project) { Project.create(name: "machine-images-service") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:machine_image) { MachineImage.create(project_id: image_project.id, location_id:, name: "ubuntu-jammy", arch: "x64") }

  before do
    admin_account_setup_and_login
    allow(Config).to receive(:machine_images_service_project_id).and_return(image_project.id)
  end

  def create_store
    MachineImageStore.create(project_id: image_project.id, location_id:, provider: "r2", region: "auto",
      endpoint: "https://r2.example.com/", bucket: "b", access_key: "ak", secret_key: "sk")
  end

  it "lists base machine images" do
    machine_image
    visit "/base-machine-images"
    expect(page).to have_content "Base Machine Images"
    expect(page).to have_content "ubuntu-jammy"
  end

  it "shows a base machine image and starts a version build for an uncreated version" do
    create_store
    machine_image
    visit "/base-machine-images/#{machine_image.ubid}"
    expect(page).to have_content "ubuntu-jammy"

    select "20240319", from: "Version"
    click_button "Download New Version"

    expect(page).to have_flash_notice(/Started base machine image version build/)
    st = Strand.where(prog: "MachineImage::CreateBaseVersion").first
    expect(st.stack[0]["version"]).to eq "20240319"
    expect(st.stack[0]["machine_image_id"]).to eq machine_image.id
  end

  it "lists only the in-progress builds for this machine image" do
    create_store
    machine_image
    Prog::MachineImage::CreateBaseVersion.assemble(name: "ubuntu-jammy", version: "20240319", location_id:)
    MachineImage.create(project_id: image_project.id, location_id:, name: "ubuntu-noble", arch: "x64")
    Prog::MachineImage::CreateBaseVersion.assemble(name: "ubuntu-noble", version: "20240702", location_id:)

    visit "/base-machine-images/#{machine_image.ubid}"
    within(".base-machine-image-builds-table") do
      expect(page).to have_content("20240319")
      expect(page).to have_no_content("20240702")
    end
  end

  it "does not offer versions that already exist" do
    create_store
    MachineImageVersion.create(machine_image_id: machine_image.id, version: "20240319", actual_size_mib: nil)
    visit "/base-machine-images/#{machine_image.ubid}"
    expect(page).to have_content "20240319"
    expect(page).to have_no_select("Version", with_options: ["20240319"])
  end

  it "flashes an error when the version build cannot be started" do
    machine_image # no machine image store
    visit "/base-machine-images/#{machine_image.ubid}"
    select "20250508", from: "Version"
    click_button "Download New Version"
    expect(page).to have_flash_error(/no machine image store/)
  end

  it "shows no available versions for an image not in the boot image catalog" do
    MachineImage.create(project_id: image_project.id, location_id:, name: "custom-image", arch: "x64")
    mi = MachineImage.first(name: "custom-image")
    visit "/base-machine-images/#{mi.ubid}"
    expect(page).to have_content "No new versions available"
  end

  it "does not expose machine images from other projects" do
    other = MachineImage.create(project_id: Project.create(name: "other").id, location_id:, name: "ubuntu-noble", arch: "x64")
    dont_raise_admin_errors do
      visit "/base-machine-images/#{other.ubid}"
    end
    expect(page.status_code).to eq 404
  end
end
