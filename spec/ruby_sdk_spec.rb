# frozen_string_literal: true

require_relative "spec_helper"

require_relative "../sdk/ruby/lib/ubicloud"
require_relative "../sdk/ruby/lib/ubicloud/adapter"
require_relative "../sdk/ruby/lib/ubicloud/adapter/net_http"

require "rack/mock_request"

# rubocop:disable RSpec/SpecFilePathFormat
RSpec.describe Ubicloud do
  # rubocop:enable RSpec/SpecFilePathFormat
  let(:ubi) { described_class.new(:rack, app: Clover, env: {}, project_id: nil) }

  it "ModelAdapter#respond_to? works as expected" do
    expect(ubi.vm).to respond_to(:create)
    expect(ubi.vm).to respond_to(:list)
    expect(ubi.vm).not_to respond_to(:invalid_meth)
  end

  it "Error#params returns empty hash for no body" do
    expect(Ubicloud::Error.new("foo").params).to eq({})
  end

  it "Error#params returns empty hash for invalid JSON" do
    expect(Ubicloud::Error.new("foo", code: 444, body: "x").params).to eq({})
  end

  it "Adapter::Rack closes response bodies" do
    o = ["{\"items\": []}"]
    closed = false
    o.define_singleton_method(:close) { closed = true }
    expect(Clover).to receive(:call).and_return([200, {"content-type" => "application/json"}, o])
    expect(ubi.vm.list).to eq([])
    expect(closed).to be true
  end

  it "Model.new raises for invalid hash" do
    expect(Clover).not_to receive(:call)
    expect { ubi.vm.new({}) }.to raise_error(Ubicloud::Error, "hash must have :id key or :location and :name keys")
    expect { ubi.vm.new({name: "foo"}) }.to raise_error(Ubicloud::Error, "hash must have :id key or :location and :name keys")
    expect { ubi.vm.new({location: "foo"}) }.to raise_error(Ubicloud::Error, "hash must have :id key or :location and :name keys")
    expect(ubi.vm.new({name: "foo", location: "foo"})).to be_a(Ubicloud::Vm)
  end

  it "Model.[] raises for invalid id or location/name format" do
    expect(Clover).not_to receive(:call)
    expect { ubi.vm["test-vm"] }.to raise_error(Ubicloud::Error, "invalid vm location/name: \"test-vm\"")
  end

  it "Model.[] assumes location/name for invalid id format" do
    expect(Clover).to receive(:call).and_return([404, {}, []])
    expect(ubi.vm["eu-north-h1/test-vm"]).to be_nil
  end

  it "Model.[] returns nil for valid id format but missing object" do
    expect(Clover).to receive(:call).and_return([404, {}, []])
    expect(ubi.vm["vm345678901234567890123456"]).to be_nil
  end

  it "Context#[] returns nil for invalid format" do
    expect(ubi["foo"]).to be_nil
  end

  it "Context#[] returns nil for valid format but missing object" do
    expect(Clover).to receive(:call).and_return([404, {}, []])
    expect(ubi["vm345678901234567890123456"]).to be_nil
  end

  it "supports inference api keys" do
    account = Account.create_with_id(email: "user@example.com", status_id: 2)
    project = account.create_project_with_default_policy("test")
    pat = ApiKey.create_personal_access_token(account, project:)
    SubjectTag.first(project_id: project.id, name: "Admin").add_subject(pat.id)
    iak = ApiKey.create_inference_api_key(project)
    env = Rack::MockRequest.env_for("http://api.localhost/cli")
    env["HTTP_AUTHORIZATION"] = "Bearer: pat-#{pat.ubid}-#{pat.key}"
    ubi = described_class.new(:rack, app: Clover, env:, project_id: project.ubid)
    expect(ubi[iak.ubid].to_h).to eq(id: iak.ubid, key: iak.key)

    expect { ubi.inference_api_key.new("badc0j48r8kj4nharh6yagf3eb") }.to raise_error(Ubicloud::Error)
    expect { ubi.inference_api_key.new(foo: "badc0j48r8kj4nharh6yagf3eb") }.to raise_error(Ubicloud::Error)
    expect { ubi.inference_api_key.new(Object.new) }.to raise_error(Ubicloud::Error)
  end

  it "Context#new returns nil for invalid format" do
    expect(ubi.new("foo")).to be_nil
  end

  it "Context#new returns object for valid format but missing object" do
    expect(Clover).not_to receive(:call)
    expect(ubi.new("vm345678901234567890123456")).to be_a(Ubicloud::Vm)
  end

  it "Firewall#attach/detach_subnet supports PrivateSubnet instances" do
    fw = ubi.firewall.new("eu-central-h1/test-fw")
    ps = ubi.private_subnet.new("ps345678901234567890123456")
    path = params = nil
    expect(Clover).to receive(:call).twice.and_invoke(proc do |env|
      path = env["PATH_INFO"]
      params = JSON.parse(env["rack.input"].read, symbolize_names: true)
      [200, {"content-type" => "application/json"}, ["{\"id\": \"ps345678901234567890123456\"}"]]
    end)

    fw.attach_subnet(ps)
    expect(path).to eq "/project//location/eu-central-h1/firewall/test-fw/attach-subnet"
    expect(params).to eq({private_subnet_id: "ps345678901234567890123456"})

    fw.detach_subnet(ps)
    expect(path).to eq "/project//location/eu-central-h1/firewall/test-fw/detach-subnet"
    expect(params).to eq({private_subnet_id: "ps345678901234567890123456"})
  end

  it "Vm.create converts LF to CRLF in public_keys" do
    public_key = nil
    expect(Clover).to receive(:call).twice.and_invoke(proc do |env|
      public_key = JSON.parse(env["rack.input"].read, symbolize_names: true)[:public_key]
      [200, {"content-type" => "application/json"}, ["{\"id\": \"vm345678901234567890123456\"}"]]
    end)

    expect(ubi.vm.create(location: "eu-central-h1", name: "test-vm", public_key: "foo\nbar\r\nbaz")).to be_a(Ubicloud::Vm)
    expect(public_key).to eq "foo\r\nbar\r\nbaz"

    expect(ubi.vm.create(location: "eu-central-h1", name: "test-vm")).to be_a(Ubicloud::Vm)
    expect(public_key).to be_nil
  end

  it "Firewall#add_rule and #delete_rule work without firewall rules loaded" do
    expect(Clover).to receive(:call).twice.and_invoke(proc do |env|
      [200, {"content-type" => "application/json"}, ["{}"]]
    end)

    fw = ubi.firewall.new("foo/bar")
    expect(fw.values[:firewall_rules]).to be_nil
    fw.add_rule("1.2.3.0/24")
    expect(fw.values[:firewall_rules]).to be_nil
    fw.delete_rule("fr345678901234567890123456")
    expect(fw.values[:firewall_rules]).to be_nil
  end

  it "Postgres#add_firewall_rule and #delete_firewall_rule work without firewall rules loaded" do
    expect(Clover).to receive(:call).twice.and_invoke(proc do |env|
      [200, {"content-type" => "application/json"}, ["{}"]]
    end)

    pg = ubi.postgres.new("foo/bar")
    expect(pg.values[:firewall_rules]).to be_nil
    pg.add_firewall_rule("1.2.3.0/24")
    expect(pg.values[:firewall_rules]).to be_nil
    pg.delete_firewall_rule("fr345678901234567890123456")
    expect(pg.values[:firewall_rules]).to be_nil
  end

  it "Postgres#add_metric_destination and #delete_metric_destination work without firewall rules loaded" do
    expect(Clover).to receive(:call).twice.and_invoke(proc do |env|
      [200, {"content-type" => "application/json"}, ["{}"]]
    end)

    pg = ubi.postgres.new("foo/bar")
    expect(pg.values[:metric_destinations]).to be_nil
    pg.add_metric_destination(username: "foo", password: "bar", url: "https://baz.example.com")
    expect(pg.values[:metric_destinations]).to be_nil
    pg.delete_metric_destination("md345678901234567890123456")
    expect(pg.values[:metric_destinations]).to be_nil
  end

  it "Firewall#add_rule and #delete_rule modify firewall rules if loaded" do
    expect(Clover).to receive(:call).twice.and_invoke(proc do |env|
      [200, {"content-type" => "application/json"}, ["{\"id\": \"fr345678901234567890123456\"}"]]
    end)

    fw = ubi.firewall.new(location: "foo", name: "bar", firewall_rules: [])
    expect(fw.values[:firewall_rules]).to eq([])
    fw.add_rule("1.2.3.0/24")
    expect(fw.values[:firewall_rules]).to eq([{id: "fr345678901234567890123456"}])
    fw.delete_rule("fr345678901234567890123456")
    expect(fw.values[:firewall_rules]).to eq([])
  end

  it "Postgres#add_firewall_rule and #delete_firewall_rule modify firewall rules if loaded" do
    expect(Clover).to receive(:call).twice.and_invoke(proc do |env|
      [200, {"content-type" => "application/json"}, ["{\"id\": \"fr345678901234567890123456\"}"]]
    end)

    pg = ubi.postgres.new(location: "foo", name: "bar", firewall_rules: [])
    expect(pg.values[:firewall_rules]).to eq([])
    pg.add_firewall_rule("1.2.3.0/24")
    expect(pg.values[:firewall_rules]).to eq([{id: "fr345678901234567890123456"}])
    pg.delete_firewall_rule("fr345678901234567890123456")
    expect(pg.values[:firewall_rules]).to eq([])
  end

  it "Postgres#add_metric_destination and #delete_metric_destination modify metric destinations if loaded" do
    expect(Clover).to receive(:call).twice.and_invoke(proc do |env|
      [200, {"content-type" => "application/json"}, ["{\"id\": \"md345678901234567890123456\"}"]]
    end)

    pg = ubi.postgres.new(location: "foo", name: "bar", metric_destinations: [])
    expect(pg.values[:metric_destinations]).to eq([])
    pg.add_metric_destination(username: "foo", password: "bar", url: "https://baz.example.com")
    expect(pg.values[:metric_destinations]).to eq([{id: "md345678901234567890123456"}])
    pg.delete_metric_destination("md345678901234567890123456")
    expect(pg.values[:metric_destinations]).to eq([])
  end

  describe Ubicloud::Adapter::NetHttp do
    let(:adapter) { described_class.new(token: "foo", project_id: "pj", base_uri: "http://localhost") }

    it "sends expected headers for GET requests" do
      stub_request(:get, "http://localhost/project/pj/headers")
        .with(
          headers: {
            "Accept" => "text/plain",
            "Accept-Encoding" => "gzip;q=1.0,deflate;q=0.6,identity;q=0.3",
            "Authorization" => "Bearer: foo",
            "Connection" => "close",
            "User-Agent" => "Ruby"
          }
        )
        .to_return(status: 200, body: "{}", headers: {"content-type" => "application/json"})
      expect(adapter.get("headers")).to eq({})
    end

    it "sends expected headers for POST requests" do
      stub_request(:post, "http://localhost/project/pj/headers")
        .with(
          body: "{\"foo\":\"bar\"}",
          headers: {
            "Accept" => "text/plain",
            "Accept-Encoding" => "gzip;q=1.0,deflate;q=0.6,identity;q=0.3",
            "Authorization" => "Bearer: foo",
            "Connection" => "close",
            "Content-Type" => "application/json",
            "User-Agent" => "Ruby"
          }
        )
        .to_return(status: 200, body: "{}", headers: {"content-type" => "application/json", "test-array" => ["a", "b"]})
      expect(adapter.post("headers", foo: "bar")).to eq({})
    end

    it "sends expected headers and body for POST requests" do
      stub_request(:post, "http://localhost/project/pj/headers")
        .with(
          headers: {
            "Accept" => "text/plain",
            "Accept-Encoding" => "gzip;q=1.0,deflate;q=0.6,identity;q=0.3",
            "Authorization" => "Bearer: foo",
            "Connection" => "close",
            "Content-Type" => "application/json",
            "User-Agent" => "Ruby"
          }
        )
        .to_return(status: 200, body: "{}", headers: {"content-type" => "application/json"})
      expect(adapter.post("headers")).to eq({})
    end

    it "sends expected headers for DELETE requests" do
      stub_request(:delete, "http://localhost/project/pj/headers")
        .with(
          headers: {
            "Accept" => "text/plain",
            "Accept-Encoding" => "gzip;q=1.0,deflate;q=0.6,identity;q=0.3",
            "Authorization" => "Bearer: foo",
            "Connection" => "close",
            "Content-Type" => "application/json",
            "User-Agent" => "Ruby"
          }
        )
        .to_return(status: 200, body: "{}", headers: {"content-type" => "application/json"})
      expect(adapter.delete("headers")).to eq({})
    end
  end
end
