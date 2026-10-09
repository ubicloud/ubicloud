# frozen_string_literal: true

require "open3"

RSpec.describe GcpDualNicNetplan do
  subject(:netplan) {
    described_class.new(mgmt_ip: "100.64.0.5", mgmt_gateway: "100.64.0.1", user_ip: "10.0.0.5", user_gateway: "10.0.0.1")
  }

  let(:network) { YAML.safe_load(netplan.to_yaml)["network"] }

  it "keeps the DHCP address of nic0 but none of its routes" do
    expect(network["ethernets"]["mgmt-nic"]).to eq(
      "match" => {"macaddress" => "@MGMT_MAC@"},
      "dhcp4" => true,
      "dhcp4-overrides" => {"use-routes" => false},
      "routes" => [
        {"to" => "169.254.169.254/32", "via" => "100.64.0.1", "on-link" => true},
        {"to" => "0.0.0.0/0", "via" => "100.64.0.1", "on-link" => true, "table" => 100},
      ],
      "routing-policy" => [{"from" => "100.64.0.5/32", "table" => 100}],
    )
  end

  it "puts the default routes on the user VLAN, in the main table and in table 200" do
    expect(network["vlans"]["user-nic"]).to eq(
      "id" => 2,
      "link" => "mgmt-nic",
      "macaddress" => "@USER_MAC@",
      "mtu" => 1460,
      "accept-ra" => false,
      "addresses" => ["10.0.0.5/32", "@USER_IPV6@/128"],
      "routes" => [
        {"to" => "0.0.0.0/0", "via" => "10.0.0.1", "on-link" => true},
        {"to" => "::/0", "via" => "@USER_GATEWAY_IPV6@"},
        {"to" => "0.0.0.0/0", "via" => "10.0.0.1", "on-link" => true, "table" => 200},
        {"to" => "::/0", "via" => "@USER_GATEWAY_IPV6@", "table" => 200},
      ],
      "routing-policy" => [
        {"from" => "10.0.0.5/32", "table" => 200},
        {"from" => "@USER_IPV6@/128", "table" => 200},
      ],
    )
  end

  it "quotes every placeholder, so the filled values stay strings" do
    yaml = netplan.to_yaml
    %w[@MGMT_MAC@ @USER_MAC@ @USER_IPV6@ @USER_GATEWAY_IPV6@].each do |placeholder|
      expect(yaml.scan(placeholder).size).to eq(yaml.scan(/["']#{placeholder}/).size)
    end
  end

  it "writes the template, fills it from metadata, then syncs and applies" do
    script = netplan.script
    template = script[/^echo (.*?) > \/etc\/netplan\/61-ubicloud\.yaml\.template$/m, 1].shellsplit.first
    fill = script[/^python3 -c (.*?)\necho 'network/m, 1].shellsplit.first

    expect(template).to eq(netplan.to_yaml.chomp)
    expect(fill).to eq(described_class::FILL_TEMPLATE)
    steps = ["set -e\n", "python3 -c", "99-disable-network-config.cfg", "! -name 61-ubicloud.yaml -delete", "\nsync\n", "netplan apply"]
    expect(steps.map { script.index(it) }).to eq(steps.map { script.index(it) }.sort)
    expect(script).not_to include("umask")
  end

  it "reads both NICs from the metadata server and writes the netplan atomically" do
    fill = described_class::FILL_TEMPLATE
    expect(fill).to include('metadata("network-interfaces/0")', 'metadata("vlan-network-interfaces/0/2")')
    expect(fill).to include("os.O_CREAT | os.O_TRUNC, 0o600", "os.fsync(f.fileno())", 'os.rename(path + ".new", path)')
    _, err, status = Open3.capture3("python3", "-c", "import ast, sys; ast.parse(sys.stdin.read())", stdin_data: fill)
    expect(status).to be_success, err
  end
end
