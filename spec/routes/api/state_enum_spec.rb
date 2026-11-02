# frozen_string_literal: true

require_relative "spec_helper"

# Committee validates every response, so a request fails with status 500 if
# the model shows a state that the enum in openapi.yml lacks.
RSpec.describe Clover, "state enums" do
  {"PrivateSubnet" => PrivateSubnet::DISPLAY_STATES, "Vm" => Vm::DISPLAY_STATES}.each do |schema, states|
    it "lists in #{schema}.state each state the model shows" do
      expect(Clover::OPENAPI.components.schemas[schema].properties["state"].enum).to match_array(states)
    end
  end
end
