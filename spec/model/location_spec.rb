# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Location do
  subject(:p2_loc) { described_class.create(name: "l2", display_name: "l2", ui_name: "l2", visible: true, provider: "aws", project_id: p2_id) }

  let(:p1_id) { Project.create(name: "pj1").id }

  let(:p2_id) { Project.create(name: "pj2").id }

  let(:p1_loc) { described_class.create(name: "l1", display_name: "l1", ui_name: "l1", visible: true, provider: "aws", project_id: p1_id) }

  it ".for_project filters dataset to given project and non-project-specific locations" do
    p1_loc
    p2_loc
    expect(described_class.for_project(p1_id).select_order_map(:name)).to eq ["github-runners", "hetzner-ai", "hetzner-fsn1", "hetzner-hel1", "l1", "latitude-ai", "latitude-fra", "leaseweb-wdc02", "tr-ist-u1", "tr-ist-u1-tom"]
    expect(described_class.for_project(p2_id).select_order_map(:name)).to eq ["github-runners", "hetzner-ai", "hetzner-fsn1", "hetzner-hel1", "l2", "latitude-ai", "latitude-fra", "leaseweb-wdc02", "tr-ist-u1", "tr-ist-u1-tom"]
  end

  it ".visible_or_for_project filters dataset to given project and visible non-project-specific locations" do
    p1_loc
    p2_loc
    expect(described_class.visible_or_for_project(p1_id).select_order_map(:name)).to eq ["hetzner-fsn1", "hetzner-hel1", "l1", "leaseweb-wdc02"]
    expect(described_class.visible_or_for_project(p2_id).select_order_map(:name)).to eq ["hetzner-fsn1", "hetzner-hel1", "l2", "leaseweb-wdc02"]
  end

  it "#visible_or_for_project? returns whether the location is visible or related to the given project" do
    expect(p1_loc.visible_or_for_project?(p1_id)).to be true
    expect(p1_loc.visible_or_for_project?(p2_id)).to be false
    expect(p2_loc.visible_or_for_project?(p2_id)).to be true
    expect(p2_loc.visible_or_for_project?(p1_id)).to be false
    expect(described_class[name: "hetzner-fsn1"].visible_or_for_project?(p1_id)).to be true
    expect(described_class[name: "github-runners"].visible_or_for_project?(p1_id)).to be false
  end
end
