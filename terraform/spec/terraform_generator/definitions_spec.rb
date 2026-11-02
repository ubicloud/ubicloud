# frozen_string_literal: true

RSpec.describe TerraformGenerator::Definitions do
  def types(definitions, **parts) = TerraformGenerator.types(TerraformGenerator::Api.new(thing(**parts)), definitions)

  it "refuses an unknown key" do
    expect { types({thing: {colour: "red"}}) }.to raise_error(TerraformGenerator::SpecError, "definitions thing: unknown key colour; the keys are order")
  end

  it "refuses a name that no item path derives, naming the nearest" do
    expect { types({thng: {}}) }.to raise_error(TerraformGenerator::SpecError, "definitions thng: no item path derives this name; the nearest are thing")
    expect { types({gizmo: {}}) }.to raise_error(TerraformGenerator::SpecError, "definitions gizmo: no item path derives this name")
  end

  describe "order" do
    let(:parts) { {create: {color: {type: "string"}}, response: {color: {type: "string"}}, ops: {patch: op("updateThing", {color: {type: "string"}})}} }

    it "refuses an order that names no verb, on a type with verbs or without" do
      expect { types({thing: {order: %i[upgrade]}}, **parts) }.to raise_error(TerraformGenerator::SpecError, "definitions thing order: upgrade names no verb; the verbs are patch")
      expect { types({thing: {order: %i[upgrade]}}, item: "/thing/{thing_reference}") }.to raise_error(TerraformGenerator::SpecError, "definitions thing order: upgrade names no verb")
    end
  end
end
