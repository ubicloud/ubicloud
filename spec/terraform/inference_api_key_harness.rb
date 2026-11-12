# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "ubicloud_inference_api_key" do
  def keys = ApiKey.where(project_id: project.id, used_for: "inference_endpoint")

  it "keeps the id and key the API returned" do
    tf.apply 'resource "ubicloud_inference_api_key" "app" {}'

    key = keys.single_record
    expect(tf.state("ubicloud_inference_api_key.app")).to include("id" => key.ubid, "key" => key.key)
  end

  it "reports the import to run, and adopts nothing, when a proxy answers 502 after the API created it" do
    at(:response, "POST inference-api-key") { it.answer(502) }

    expect { tf.apply 'resource "ubicloud_inference_api_key" "app" {}' }
      .to raise_error(TerraformHarness::Error, /with ubicloud_inference_api_key\.app,.*terraform import ADDRESS ID/m)
    expect(ledger.requests).to eq ["POST inference-api-key"]
    expect(keys.count).to eq 1
    expect(tf.state).to be_empty
  end
end
