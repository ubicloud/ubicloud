# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe GcpDualNicNetplan do
  subject(:netplan) {
    described_class.new(mgmt_ip: "100.64.0.5", mgmt_gateway: "100.64.0.1", user_ip: "10.0.0.5", user_gateway: "10.0.0.1", mgmt_ipv6: false)
  }

  let(:network) { YAML.safe_load(netplan.to_yaml)["network"] }
  let(:ipv6_netplan) { netplan.with(mgmt_ipv6: true) }
  let(:metadata) {
    {
      "network-interfaces/0/mac" => "42:01:64:40:00:05",
      "network-interfaces/0/ipv6s" => "2600:1900:4000:7:0:0:0:0\n",
      "network-interfaces/0/gateway-ipv6" => "fe80::1",
      "vlan-network-interfaces/0/2/mac" => "42:01:0a:00:00:05",
      "vlan-network-interfaces/0/2/ipv6s" => "2600:1900:4000:9:0:1:0:0\n",
      "vlan-network-interfaces/0/2/gateway-ipv6" => "fe80::2",
    }
  }

  def fill(netplan, dir, metadata)
    path = File.join(dir, "61-ubicloud.yaml")
    File.write("#{path}.template", netplan.to_yaml)
    metadata.each do |key, value|
      FileUtils.mkdir_p(File.join(dir, "metadata", File.dirname(key)))
      File.write(File.join(dir, "metadata", key), value)
    end
    FileUtils.mkdir_p(File.join(dir, "bin"))
    File.write(File.join(dir, "bin", "curl"), "#!/bin/sh\nfor url; do :; done\ncat \"#{dir}/metadata/${url#*/instance/}\" 2>/dev/null || exit 22\n", perm: 0o755)
    File.write(File.join(dir, "bin", "sleep"), "#!/bin/sh\necho \"$1\" >> \"#{dir}/sleeps\"\n", perm: 0o755)
    script = described_class::FILL_TEMPLATE.sub(described_class::NETPLAN_PATH, path)
    _, err, status = Open3.capture3({"PATH" => "#{dir}/bin:#{ENV["PATH"]}"}, "sh", "-ec", script)
    [path, err, status]
  end

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

  it "gives nic0 its external IPv6 address, with the default route only in table 100, with mgmt_ipv6" do
    mgmt = YAML.safe_load(ipv6_netplan.to_yaml)["network"]["ethernets"]["mgmt-nic"]
    expect(mgmt).to include(
      "accept-ra" => false,
      "addresses" => ["@MGMT_IPV6@/128"],
      "routes" => [
        {"to" => "169.254.169.254/32", "via" => "100.64.0.1", "on-link" => true},
        {"to" => "0.0.0.0/0", "via" => "100.64.0.1", "on-link" => true, "table" => 100},
        {"to" => "::/0", "via" => "@MGMT_GATEWAY_IPV6@", "table" => 100},
      ],
      "routing-policy" => [
        {"from" => "100.64.0.5/32", "table" => 100},
        {"from" => "@MGMT_IPV6@/128", "table" => 100},
      ],
    )
    expect(YAML.safe_load(ipv6_netplan.to_yaml)["network"]["vlans"]).to eq(network["vlans"])
  end

  it "quotes every placeholder, so the filled values stay strings" do
    yaml = ipv6_netplan.to_yaml
    %w[@MGMT_MAC@ @MGMT_IPV6@ @MGMT_GATEWAY_IPV6@ @USER_MAC@ @USER_IPV6@ @USER_GATEWAY_IPV6@].each do |placeholder|
      expect(yaml.scan(placeholder).size).to be > 0
      expect(yaml.scan(placeholder).size).to eq(yaml.scan(/["']#{placeholder}/).size)
    end
  end

  it "fills the template from the metadata of both NICs" do
    Dir.mktmpdir do |dir|
      path, err, status = fill(netplan, dir, metadata)
      expect(status).to be_success, err
      expect(File).not_to exist("#{path}.template")
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      filled = File.read(path)
      expect(filled).not_to include("@")
      network = YAML.safe_load(filled)["network"]
      expect(network["ethernets"]["mgmt-nic"]["match"]).to eq("macaddress" => "42:01:64:40:00:05")
      expect(network["ethernets"]["mgmt-nic"]).not_to have_key("addresses")
      user = network["vlans"]["user-nic"]
      expect(user["macaddress"]).to eq("42:01:0a:00:00:05")
      expect(user["addresses"]).to eq(["10.0.0.5/32", "2600:1900:4000:9:0:1:0:0/128"])
      expect(user["routes"].map { it["via"] }).to eq(["10.0.0.1", "fe80::2", "10.0.0.1", "fe80::2"])
    end
  end

  it "fills the IPv6 address and gateway of nic0 with mgmt_ipv6" do
    Dir.mktmpdir do |dir|
      path, err, status = fill(ipv6_netplan, dir, metadata)
      expect(status).to be_success, err
      filled = File.read(path)
      expect(filled).not_to include("@")
      mgmt = YAML.safe_load(filled)["network"]["ethernets"]["mgmt-nic"]
      expect(mgmt["addresses"]).to eq(["2600:1900:4000:7:0:0:0:0/128"])
      expect(mgmt["routes"].last).to eq("to" => "::/0", "via" => "fe80::1", "table" => 100)
      expect(mgmt["routing-policy"].last).to eq("from" => "2600:1900:4000:7:0:0:0:0/128", "table" => 100)
    end
  end

  it "writes no netplan when the metadata server returns an unexpected value" do
    Dir.mktmpdir do |dir|
      path, err, status = fill(netplan, dir, metadata.merge("vlan-network-interfaces/0/2/mac" => "42:01:0a:00:00:05\" x"))
      expect(status).not_to be_success
      expect(err).to include("unexpected vlan-network-interfaces/0/2/mac from metadata")
      expect(File).not_to exist(path)
    end
  end

  it "retries 60 times, then stops when the metadata server does not answer" do
    Dir.mktmpdir do |dir|
      path, err, status = fill(netplan, dir, metadata.except("vlan-network-interfaces/0/2/gateway-ipv6"))
      expect(status).not_to be_success
      expect(err).to include("metadata server did not answer for vlan-network-interfaces/0/2/gateway-ipv6")
      expect(File.read(File.join(dir, "sleeps")).lines).to eq(["2\n"] * 60)
      expect(File).not_to exist(path)
    end
  end

  it "writes the template, fills it from metadata, then syncs and applies" do
    script = netplan.script
    template = script[/^echo (.*?) > \/etc\/netplan\/61-ubicloud\.yaml\.template$/m, 1].shellsplit.first

    expect(template).to eq(netplan.to_yaml.chomp)
    expect(script).to include(described_class::FILL_TEMPLATE)
    steps = ["set -e\n", described_class::FILL_TEMPLATE, "99-disable-network-config.cfg", "! -name 61-ubicloud.yaml -delete", "\nsync\n", "netplan apply"]
    expect(steps.map { script.index(it) }).to eq(steps.map { script.index(it) }.sort)
    expect(script).not_to include("umask")
    _, err, status = Open3.capture3("sh", "-n", stdin_data: script)
    expect(status).to be_success, err
  end
end
