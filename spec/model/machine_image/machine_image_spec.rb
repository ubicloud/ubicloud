# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MachineImage do
  describe "#admin_label" do
    it "qualifies the name with the location's display name" do
      project = Project.create(name: "p")
      mi = described_class.create(name: "ubuntu-noble", arch: "x64", project_id: project.id, location_id: Location::HETZNER_FSN1_ID)
      expect(mi.admin_label).to eq("ubuntu-noble (#{Location[Location::HETZNER_FSN1_ID].display_name})")
    end
  end
end
