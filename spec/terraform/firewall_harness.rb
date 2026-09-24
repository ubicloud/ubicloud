# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "terraform: ubicloud_firewall" do
  it "creates a firewall on apply and removes it on destroy" do
    runner = tf_runner("firewall_basic.tf.erb", name: "tf-hello")
    expect(tf_project.firewalls).to be_empty

    runner.apply

    # DB-side: the row exists, committed, with the attributes terraform
    # sent; terraform-side: state agrees with the DB.
    fw = Firewall.first(project_id: tf_project.id)
    expect(fw.name).to eq "tf-hello"
    expect(fw.location.display_name).to eq TerraformHarness::LOCATION

    resources = runner.state_resources
    expect(resources.length).to eq 1
    attrs = resources[0]["values"]
    expect(attrs["name"]).to eq "tf-hello"
    expect(attrs["id"]).to eq fw.ubid

    runner.destroy

    expect(Firewall.first(project_id: tf_project.id)).to be_nil
  end

  it "reads a firewall through the generated datasource" do
    runner = tf_runner("firewall_with_data.tf.erb", name: "tf-ds")
    runner.apply

    fw = Firewall.first(project_id: tf_project.id, name: "tf-ds")
    fw.insert_firewall_rule("10.1.0.0/16", Sequel.pg_range(443..443))

    # Re-apply refreshes the data source; its state must carry the
    # generated mapper's view: scalars plus the nested rule list.
    runner.apply
    data = runner.state_resources.find { it["address"] == "data.ubicloud_firewall.fw" }["values"]
    expect(data.values_at("id", "name")).to eq [fw.ubid, "tf-ds"]
    project_data = runner.state_resources.find { it["address"] == "data.ubicloud_project.pj" }["values"]
    expect(project_data.values_at("id", "name")).to eq [tf_project.ubid, "tf-project"]

    rule = data["firewall_rules"].find { it["cidr"] == "10.1.0.0/16" }
    expect(rule["port_range"]).to eq "443"
    expect(rule["id"]).to match(/\A[a-z0-9]{26}\z/)
  end
end
