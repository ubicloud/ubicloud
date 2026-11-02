# frozen_string_literal: true

RSpec.describe TerraformGenerator, ".special_cases" do
  it "names each definition key and each clause with the types it shaped" do
    api = TerraformGenerator::Api.new(thing(create: {color: {type: "string"}}, response: {color: {type: "string"}, size: {type: "string"}},
      ops: {post: op("updateThing", {color: {type: "string"}})}, paths: {"/thing/{thing_id}/resize" => {post: op("resizeThing", {size: {type: "string"}})}}))
    expect(described_class.special_cases(api, {thing: {order: %i[resize]}})).to eq("definitions order" => %i[thing], "item_post_verb" => %i[thing])
  end

  # A commit that adds a special case must change this pin, so that review
  # sees it by name.
  it "pins the special cases of the definitions" do
    expect(described_class.special_cases).to eq("item_post_verb" => %i[ssh_public_key])
  end
end
