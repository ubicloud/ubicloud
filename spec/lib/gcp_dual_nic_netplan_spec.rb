# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe GcpDualNicNetplan do
  subject(:netplan) {
    described_class.new(mgmt_ip: "100.64.0.5", mgmt_gateway: "100.64.0.1", user_ip: "10.0.0.5", user_gateway: "10.0.0.1", mgmt_ipv6: false)
  }

  let(:network) { YAML.safe_load(netplan.to_yaml)["network"] }
  let(:ipv6_netplan) { netplan.with(mgmt_ipv6: true) }

  # Runs the fill script against a fake metadata server and returns the
  # written netplan.
  def fill(netplan, dir)
    path = File.join(dir, "61-ubicloud.yaml")
    File.write("#{path}.template", netplan.to_yaml)
    metadata = {
      "network-interfaces/0" => {"mac" => "42:01:64:40:00:05", "ipv6s" => ["2600:1900:4000:7::"], "gatewayIpv6" => "fe80::1"},
      "vlan-network-interfaces/0/2" => {"mac" => "42:01:0a:00:00:05", "ipv6s" => ["2600:1900:4000:9:0:1::"], "gatewayIpv6" => "fe80::2"},
    }
    harness = <<~PYTHON
      import io, json, sys, time, urllib.request
      fake_metadata = json.loads(sys.argv[1])
      def urlopen(req, timeout):
          return io.BytesIO(json.dumps(fake_metadata[req.full_url.split("/instance/")[1].removesuffix("/?recursive=true")]).encode())
      def no_retry(_):
          raise SystemExit("metadata request failed")
      urllib.request.urlopen = urlopen
      time.sleep = no_retry
      exec(sys.stdin.read())
    PYTHON
    script = described_class::FILL_TEMPLATE.sub(described_class::NETPLAN_PATH, path)
    _, err, status = Open3.capture3("python3", "-c", harness, metadata.to_json, stdin_data: script)
    expect(status).to be_success, err
    expect(File).not_to exist("#{path}.template")
    expect(File.stat(path).mode & 0o777).to eq(0o600)
    File.read(path)
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
      filled = fill(netplan, dir)
      expect(filled).not_to include("@")
      network = YAML.safe_load(filled)["network"]
      expect(network["ethernets"]["mgmt-nic"]["match"]).to eq("macaddress" => "42:01:64:40:00:05")
      expect(network["ethernets"]["mgmt-nic"]).not_to have_key("addresses")
      user = network["vlans"]["user-nic"]
      expect(user["macaddress"]).to eq("42:01:0a:00:00:05")
      expect(user["addresses"]).to eq(["10.0.0.5/32", "2600:1900:4000:9:0:1::/128"])
      expect(user["routes"].map { it["via"] }).to eq(["10.0.0.1", "fe80::2", "10.0.0.1", "fe80::2"])
    end
  end

  it "fills the IPv6 address and gateway of nic0 with mgmt_ipv6" do
    Dir.mktmpdir do |dir|
      filled = fill(ipv6_netplan, dir)
      expect(filled).not_to include("@")
      mgmt = YAML.safe_load(filled)["network"]["ethernets"]["mgmt-nic"]
      expect(mgmt["addresses"]).to eq(["2600:1900:4000:7::/128"])
      expect(mgmt["routes"].last).to eq("to" => "::/0", "via" => "fe80::1", "table" => 100)
      expect(mgmt["routing-policy"].last).to eq("from" => "2600:1900:4000:7::/128", "table" => 100)
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
