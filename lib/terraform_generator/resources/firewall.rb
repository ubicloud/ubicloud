# frozen_string_literal: true

TerraformGenerator.resource :firewall do
  serializer Serializers::Firewall

  # private_subnets is the detailed serializer's deep subnet graph,
  # not a firewall property terraform should own.
  omit :private_subnets
  # The published datasource lists rules by cidr and ports only.
  omit "firewall_rules.protocol", "firewall_rules.description", kinds: [:datasource]

  fixture do
    project = Project.create(name: "gen-reflect")
    fw = Firewall.create(name: "gen-fw", description: "d",
      location_id: Location::HETZNER_FSN1_ID, project_id: project.id)
    fw.insert_firewall_rule("10.0.0.0/8", Sequel.pg_range(80..80))
    fw
  end
end
