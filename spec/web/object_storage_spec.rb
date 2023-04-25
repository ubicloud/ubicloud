# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "object_storage" do
  it "can not access without login" do
    visit "/object-storage"

    expect(page.title).to eq("Ubicloud - Login")
  end

  describe "authenticated" do
    before do
      login
    end

    it "show service is under development" do
      visit "/object-storage"

      expect(page.title).to eq("Ubicloud - Object Storage")
      expect(page).to have_content "This service is under development"
    end
  end
end
