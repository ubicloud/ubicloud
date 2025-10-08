# frozen_string_literal: true

require_relative "spec_helper"

require_relative "../sdk/ruby/lib/ubicloud"
require_relative "../sdk/ruby/lib/ubicloud/adapter"
require_relative "../sdk/ruby/lib/ubicloud/adapter/net_http"

require "rack/mock_request"

# rubocop:disable RSpec/SpecFilePathFormat
RSpec.describe Ubicloud do
  # rubocop:enable RSpec/SpecFilePathFormat
  let(:ubi) { described_class.new(:rack, app: Clover, env: {}, project_id:) }
  let(:project_id) { Project.generate_ubid.to_s }

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

  it "Model.new raises for invalid object" do
    expect(Clover).not_to receive(:call)
    expect { ubi.vm.new([]) }.to raise_error(Ubicloud::Error, "unsupported value initializing Ubicloud::Vm: []")
  end

  it "Model.new does not convert association key that isn't in expected format" do
    expect(Clover).not_to receive(:call)
    object = Object.new
    expect(ubi.vm.new(location: "eu-central-h1", name: "test-vm", firewalls: object).firewalls).to eq object
  end

  it "Model.list raises for location including /" do
    expect { ubi.vm.list(location: "foo/bar") }.to raise_error(Ubicloud::Error, "invalid location: \"foo/bar\"")
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

  it "Model#id works for values with existing id" do
    id = "vm345678901234567890123456"
    expect(ubi.vm.new(id:).id).to eq id
  end

  it "Model#id retrieves id if id is not known" do
    id = "vm345678901234567890123456"
    expect(Clover).to receive(:call).and_invoke(proc do |env|
      expect(env["PATH_INFO"]).to eq "/project/#{project_id}/location/eu-central-h1/vm/test-vm"
      expect(env["REQUEST_METHOD"]).to eq "GET"
      [200, {"content-type" => "application/json"}, [{id:}.to_json]]
    end)
    expect(ubi.vm.new(location: "eu-central-h1", name: "test-vm").id).to eq id
  end

  it "Model#location works for values with existing location" do
    location = "eu-central-h1"
    expect(ubi.vm.new(location:, name: "test-vm").location).to eq location
  end

  it "Model#location retrieves location if location is not known" do
    location = "eu-central-h1"
    id = "vm345678901234567890123456"
    expect(Clover).to receive(:call).and_invoke(proc do |env|
      expect(env["PATH_INFO"]).to eq "/project/#{project_id}/object-info/#{id}"
      expect(env["REQUEST_METHOD"]).to eq "GET"
      [200, {"content-type" => "application/json"}, [{location:}.to_json]]
    end)
    expect(ubi.vm.new(id:).location).to eq location
  end

  it "Model#name works for values with existing name" do
    name = "test-vm"
    expect(ubi.vm.new(location: "eu-central-h1", name:).name).to eq name
  end

  it "Model#name retrieves name if name is not known" do
    name = "test-vm"
    id = "vm345678901234567890123456"
    expect(Clover).to receive(:call).and_invoke(proc do |env|
      expect(env["PATH_INFO"]).to eq "/project/#{project_id}/object-info/#{id}"
      expect(env["REQUEST_METHOD"]).to eq "GET"
      [200, {"content-type" => "application/json"}, [{name:}.to_json]]
    end)
    expect(ubi.vm.new(id:).name).to eq name
  end

  it "Context#[] returns nil for invalid format" do
    expect(ubi["foo"]).to be_nil
  end

  it "Context#[] returns nil for valid format but missing object" do
    expect(Clover).to receive(:call).and_return([404, {}, []])
    expect(ubi["vm345678901234567890123456"]).to be_nil
  end

  it "supports inference api keys" do
    account = Account.create(email: "user@example.com", status_id: 2)
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

  it "GithubInstallation.new supports id strings and performs appropriate lookups" do
    ubid = GithubInstallation.generate_ubid.to_s
    gi = ubi.github_installation.new(ubid)
    expect(gi[:id]).to eq ubid

    expected_segment = ubid
    expect(Clover).to receive(:call).twice.and_invoke(proc do |env|
      expect(env["PATH_INFO"]).to eq "/project/#{project_id}/github/#{expected_segment}"
      [200, {"content-type" => "application/json"}, [{id: ubid, name: "foo"}.to_json]]
    end)

    expect(gi.name).to eq "foo"

    expected_segment = "foo"
    gi.values.delete(:id)
    expect(gi.check_exists).to eq gi
    expect(gi.id).to eq ubid
  end

  it "GithubInstallation#repositories caches lookups unless reload keyword argument is given" do
    ubid = GithubInstallation.generate_ubid.to_s
    gi = ubi.github_installation.new(ubid)
    repo_ubid = GithubRepository.generate_ubid.to_s

    expect(Clover).to receive(:call).twice.and_invoke(proc do |env|
      expect(env["PATH_INFO"]).to eq "/project/#{project_id}/github/#{ubid}/repository"
      [200, {"content-type" => "application/json"}, [{items: [{id: repo_ubid, installation_name: "bar", name: "bar/foo"}], count: 1}.to_json]]
    end)

    repos = gi.repositories
    expect(repos.length).to eq 1
    repo = repos[0]
    expect(repo.id).to eq repo_ubid
    expect(repo.installation_name).to eq "bar"
    expect(repo.name).to eq "bar/foo"
    expect(gi.repositories).to be repos
    expect(gi.repositories(reload: true)).not_to be repos
  end

  it "GithubInstallation.new raises for invalid arguments" do
    expect(Clover).not_to receive(:call)
    expect { ubi.github_installation.new([]) }.to raise_error(Ubicloud::Error, "unsupported value initializing Ubicloud::GithubInstallation: []")
    expect { ubi.github_installation.new(foo: 1) }.to raise_error(Ubicloud::Error, "hash must have :id or :name key")
  end

  it "GithubRepository performs appropriate lookups" do
    ubid = GithubRepository.generate_ubid.to_s
    gp = ubi.github_repository.new(installation_name: "foo", id: ubid)
    expect(gp[:id]).to eq ubid

    expected_segment = ubid
    expect(Clover).to receive(:call).twice.and_invoke(proc do |env|
      expect(env["PATH_INFO"]).to eq "/project/#{project_id}/github/foo/repository/#{expected_segment}"
      [200, {"content-type" => "application/json"}, [{id: ubid, installation_name: "foo", name: "bar"}.to_json]]
    end)

    expect(gp.name).to eq "bar"

    expected_segment = "bar"
    gp.values.delete(:id)
    expect(gp.check_exists).to eq gp
    expect(gp.id).to eq ubid
  end

  it "GithubRepository.new raises for invalid arguments" do
    expect(Clover).not_to receive(:call)
    expect { ubi.github_repository.new([]) }.to raise_error(Ubicloud::Error, "unsupported value initializing Ubicloud::GithubRepository: []")
    expect { ubi.github_repository.new(installation_name: "foo") }.to raise_error(Ubicloud::Error, "hash must have :installation_name key and either :id or :name keys")
    expect { ubi.github_repository.new(name: "foo") }.to raise_error(Ubicloud::Error, "hash must have :installation_name key and either :id or :name keys")
  end

  it "GithubRepository#cache_entries caches lookups unless reload keyword argument is given" do
    ubid = GithubRepository.generate_ubid.to_s
    gp = ubi.github_repository.new(installation_name: "foo", id: ubid)
    ce_ubid = GithubCacheEntry.generate_ubid.to_s

    expect(Clover).to receive(:call).twice.and_invoke(proc do |env|
      expect(env["PATH_INFO"]).to eq "/project/#{project_id}/github/foo/repository/#{ubid}/cache"
      [200, {"content-type" => "application/json"}, [{items: [{id: ce_ubid, installation_name: "bar", repository_name: "bar/foo", key: "baz", size: "10 MB"}], count: 1}.to_json]]
    end)

    entries = gp.cache_entries
    expect(entries.length).to eq 1
    entry = entries[0]
    expect(entry.id).to eq ce_ubid
    expect(entry.installation_name).to eq "bar"
    expect(entry.repository_name).to eq "bar/foo"
    expect(entry.key).to eq "baz"
    expect(entry.size).to eq "10 MB"
    expect(gp.cache_entries).to be entries
    expect(gp.cache_entries(reload: true)).not_to be entries
  end

  it "GithubCache#check_exists checks whether the cache key exists" do
    ubid = GithubRepository.generate_ubid.to_s
    ge = ubi.github_cache_entry.new(installation_name: "foo", repository_name: "bar", id: ubid)
    expect(ge[:id]).to eq ubid

    expect(Clover).to receive(:call).and_invoke(proc do |env|
      expect(env["PATH_INFO"]).to eq "/project/#{project_id}/github/foo/repository/bar/cache/#{ubid}"
      [200, {"content-type" => "application/json"}, [{id: ubid, installation_name: "foo", repository_name: "bar", key: "baz"}.to_json]]
    end)

    expect(ge.check_exists).to eq ge
    expect(ge.key).to eq "baz"
  end

  it "GithubCacheEntry.new raises for invalid arguments" do
    expect(Clover).not_to receive(:call)
    expect { ubi.github_cache_entry.new([]) }.to raise_error(Ubicloud::Error, "unsupported value initializing Ubicloud::GithubCacheEntry: []")
    expect { ubi.github_cache_entry.new(id: GithubCacheEntry.generate_ubid.to_s, installation_name: "foo") }.to raise_error(Ubicloud::Error, "hash must have :id, :repository_name, and :installation_name keys")
    expect { ubi.github_cache_entry.new(id: GithubCacheEntry.generate_ubid.to_s, repository_name: "foo") }.to raise_error(Ubicloud::Error, "hash must have :id, :repository_name, and :installation_name keys")
    expect { ubi.github_cache_entry.new(repository_name: "bar", installation_name: "foo") }.to raise_error(Ubicloud::Error, "hash must have :id, :repository_name, and :installation_name keys")
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
    expect(path).to eq "/project/#{project_id}/location/eu-central-h1/firewall/test-fw/attach-subnet"
    expect(params).to eq({private_subnet_id: "ps345678901234567890123456"})

    fw.detach_subnet(ps)
    expect(path).to eq "/project/#{project_id}/location/eu-central-h1/firewall/test-fw/detach-subnet"
    expect(params).to eq({private_subnet_id: "ps345678901234567890123456"})
  end

  it "Firewall#detach_subnet raises if private subnet id includes a slash" do
    ps = ubi.private_subnet.new("eu-central-h1/test-ps")
    expect { ps.disconnect("foo/bar") }.to raise_error(Ubicloud::Error, "invalid private subnet id format")
  end

  it "SshPublicKey.new raises if given bad values" do
    expect { ubi.ssh_public_key.new("a/b") }.to raise_error(Ubicloud::Error, "invalid SSH public key id format")
    expect { ubi.ssh_public_key.new({}) }.to raise_error(Ubicloud::Error, "hash must have :id or :name key")
    expect { ubi.ssh_public_key.new([]) }.to raise_error(Ubicloud::Error, "unsupported value initializing Ubicloud::SshPublicKey: []")
  end

  it "SshPublicKey#check_exists" do
    spk = ubi.ssh_public_key.new("spk")
    expect(Clover).to receive(:call).and_return([404, {"content-type" => "application/json"}, ["{}"]])
    expect(spk.check_exists).to be_nil
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

  it "Firewall#add_rule, #modify_rule, and #delete_rule work without firewall rules loaded" do
    expect(Clover).to receive(:call).thrice.and_invoke(proc do |env|
      [200, {"content-type" => "application/json"}, ["{}"]]
    end)

    fw = ubi.firewall.new("foo/bar")
    expect(fw.values[:firewall_rules]).to be_nil
    fw.add_rule("1.2.3.0/24")
    expect(fw.values[:firewall_rules]).to be_nil
    fw.modify_rule("fr345678901234567890123456", cidr: "1.2.4.0/24")
    expect(fw.values[:firewall_rules]).to be_nil
    fw.delete_rule("fr345678901234567890123456")
    expect(fw.values[:firewall_rules]).to be_nil
  end

  it "Firewall##modify_rule raises if no options are given" do
    fw = ubi.firewall.new("foo/bar")
    expect { fw.modify_rule("fr345678901234567890123456") }.to raise_error(Ubicloud::Error, "must provide at least one keyword argument")
  end

  it "Postgres\#{add,delete,modify}_firewall_rule work without firewall rules loaded" do
    expect(Clover).to receive(:call).thrice.and_invoke(proc do |env|
      [200, {"content-type" => "application/json"}, ["{}"]]
    end)

    pg = ubi.postgres.new("foo/bar")
    expect(pg.values[:firewall_rules]).to be_nil
    pg.add_firewall_rule("1.2.3.0/24")
    expect(pg.values[:firewall_rules]).to be_nil
    pg.delete_firewall_rule("fr345678901234567890123456")
    expect(pg.values[:firewall_rules]).to be_nil
    pg.modify_firewall_rule("fr345678901234567890123456", cidr: "1.2.3.0/24")
    expect(pg.values[:firewall_rules]).to be_nil
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

  it "Firewall#add_rule, #modify_rule, and #delete_rule modify firewall rules if loaded" do
    id = "fr345678901234567890123456"
    hash = {id:}
    body = hash.to_json
    expect(Clover).to receive(:call).thrice.and_invoke(proc do |env|
      [200, {"content-type" => "application/json"}, [body]]
    end)

    fw = ubi.firewall.new(location: "foo", name: "bar", firewall_rules: [])
    expect(fw.values[:firewall_rules]).to eq([])
    fw.add_rule("1.2.3.0/24")
    expect(fw.values[:firewall_rules]).to eq([hash])
    fw.modify_rule(id, cidr: "1.2.4.0/24")
    expect(fw.values[:firewall_rules]).to eq([hash])
    fw.delete_rule(id)
    expect(fw.values[:firewall_rules]).to eq([])
  end

  it "Postgres\#{add,delete,modify}_firewall_rule modify firewall rules if loaded" do
    v = "1.2.3.0/24"
    expect(Clover).to receive(:call).exactly(4).and_invoke(proc do |env|
      [200, {"content-type" => "application/json"}, ["{\"id\": \"fr345678901234567890123456\", \"cidr\": \"#{v}\"}"]]
    end)

    pg = ubi.postgres.new(location: "foo", name: "bar", firewall_rules: [])
    expect(pg.values[:firewall_rules]).to eq([])
    pg.add_firewall_rule(v)
    expect(pg.values[:firewall_rules]).to eq([{id: "fr345678901234567890123456", cidr: v}])
    v = "1.2.4.0/24"
    pg.modify_firewall_rule("fr345678901234567890123456", cidr: v)
    expect(pg.values[:firewall_rules]).to eq([{id: "fr345678901234567890123456", cidr: v}])
    v = "1.2.5.0/24"
    pg.modify_firewall_rule("fr345678901234567890123457", cidr: v)
    expect(pg.values[:firewall_rules]).to eq([{id: "fr345678901234567890123456", cidr: "1.2.4.0/24"}])
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
