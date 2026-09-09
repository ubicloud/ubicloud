# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe FirewallRule do
  let(:fw) {
    Firewall.create(location_id: Location::HETZNER_FSN1_ID, project_id: Project.create(name: "test").id)
  }

  describe "deleted records" do
    it "keeps a deleted record for a customer firewall's rule" do
      rule = described_class.create(cidr: "::/0", firewall_id: fw.id)
      expect { rule.destroy }.to change { DeletedRecord.where(model_name: "FirewallRule").count }.by(1)
    end

    it "does not keep a deleted record for a github runner firewall's rules" do
      runner_project_id = Project.create(name: "runner-service").id
      expect(Config).to receive(:github_runner_service_project_id).at_least(:once).and_return(runner_project_id)
      runner_fw = Firewall.create(location_id: Location::HETZNER_FSN1_ID, project_id: runner_project_id)
      rule = described_class.create(cidr: "::/0", firewall_id: runner_fw.id)

      expect { rule.destroy }.not_to change { DeletedRecord.where(model_name: "FirewallRule").count }
    end
  end

  it "returns ip6? properly" do
    fw_rule = described_class.create(cidr: "::/0", firewall_id: fw.id)
    expect(fw_rule.ip6?).to be true
    fw_rule.update(cidr: "0.0.0.0/0")
    expect(fw_rule.ip6?).to be false
  end

  it "<=> sorts by family, ip address (numerically), netmask, protocol, starting port, and ending port" do
    fws = []
    fws << (fw1 = described_class.create(cidr: "1.2.3.4/31", port_range: (22...32), firewall_id: fw.id))
    fws << (fw2 = described_class.create(cidr: "1.2.3.4/31", port_range: (22...31), firewall_id: fw.id))
    expect(fws.sort).to eq [fw2, fw1]
    fws << (fw3 = described_class.create(cidr: "1.2.3.4/31", port_range: (21...33), firewall_id: fw.id))
    expect(fws.sort).to eq [fw3, fw2, fw1]
    fws << (fw4 = described_class.create(cidr: "1.2.3.4/30", port_range: (21...33), firewall_id: fw.id))
    expect(fws.sort).to eq [fw4, fw3, fw2, fw1]
    fws << (fw5 = described_class.create(cidr: "1.2.3.5/32", port_range: (21...33), firewall_id: fw.id))
    expect(fws.sort).to eq [fw4, fw3, fw2, fw1, fw5]
    fws << (fw6 = described_class.create(cidr: "::/0", port_range: (21...33), firewall_id: fw.id))
    expect(fws.sort).to eq [fw4, fw3, fw2, fw1, fw5, fw6]
    fws << (fw7 = described_class.create(cidr: "1.2.3.4/31", port_range: (22...31), protocol: "udp", firewall_id: fw.id))
    expect(fws.sort).to eq [fw4, fw3, fw2, fw1, fw7, fw5, fw6]
  end
end
