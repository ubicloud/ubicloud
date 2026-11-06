# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "data.ubicloud_project" do
  it "reads the provider's project" do
    tf.apply 'data "ubicloud_project" "this" {}'

    expect(tf.state("data.ubicloud_project.this")).to eq("id" => project.ubid, "name" => "terraform")
  end
end
