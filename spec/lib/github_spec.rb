# frozen_string_literal: true

RSpec.describe Github do
  it "creates oauth client" do
    expect(Octokit::Client).to receive(:new).with(client_id: Config.github_app_client_id, client_secret: Config.github_app_client_secret)

    described_class.oauth_client
  end

  it "creates app client" do
    expect(Config).to receive(:github_app_id).and_return("123456")
    private_key = instance_double(OpenSSL::PKey::RSA)
    expect(private_key).to receive(:is_a?).with(OpenSSL::PKey::RSA).and_return(true)
    expect(private_key).to receive(:sign).and_return("signed")
    expect(OpenSSL::PKey::RSA).to receive(:new).and_return(private_key)
    expect(Octokit::Client).to receive(:new).with(bearer_token: anything)

    described_class.app_client
  end

  it "creates installation client" do
    installation_id = 123
    app_client = instance_double(Octokit::Client)
    expect(described_class).to receive(:app_client).and_return(app_client)
    expect(app_client).to receive(:create_app_installation_access_token).with(installation_id).and_return({token: "abcdefg"})
    installation_client = instance_double(Octokit::Client)
    expect(installation_client).to receive(:auto_paginate=).with(true)
    expect(Octokit::Client).to receive(:new).with(access_token: "abcdefg").and_return(installation_client)

    described_class.installation_client(installation_id)
  end

  it "can map alias to actual label" do
    labels = described_class.runner_labels
    expect(labels["ubicloud"]).to eq(labels["ubicloud-standard-2-ubuntu-2204"])
    expect(labels["ubicloud-standard-8"]).to eq(labels["ubicloud-standard-8-ubuntu-2204"])
    expect(labels["ubicloud-standard-4-arm"]).to eq(labels["ubicloud-standard-4-arm-ubuntu-2204"])
  end

  it "can map all aliases to actual tag" do
    expect(described_class.runner_labels.values).to be_all
  end

  it ".failed_deliveries" do
    time = Time.now
    app_client = instance_double(Octokit::Client)
    expect(described_class).to receive(:app_client).and_return(app_client)
    expect(app_client).to receive(:get).with("/app/hook/deliveries?per_page=100").and_return([
      {guid: "1", status: "Fail", delivered_at: time + 5},
      {guid: "2", status: "Fail", delivered_at: time + 4},
      {guid: "3", status: "OK", delivered_at: time + 3}
    ])
    next_url = "/app/hook/deliveries?per_page=100&cursor=next_page"
    expect(app_client).to receive(:last_response).and_return(instance_double(Sawyer::Response, rels: {next: instance_double(Sawyer::Relation, href: next_url)}))
    expect(app_client).to receive(:last_response).and_return(instance_double(Sawyer::Response, rels: {next: nil}))
    expect(app_client).to receive(:get).with(next_url).and_return([
      {guid: "2", status: "OK", delivered_at: time + 2},
      {guid: "4", status: "Fail", delivered_at: time + 2},
      {guid: "4", status: "Fail", delivered_at: time + 1},
      {guid: "5", status: "Fail", delivered_at: time - 2},
      {guid: "6", status: "OK", delivered_at: time - 3}
    ])

    failed_deliveries = described_class.failed_deliveries(time)
    expect(failed_deliveries).to eq([
      {guid: "1", status: "Fail", delivered_at: time + 5},
      {guid: "4", status: "Fail", delivered_at: time + 2}
    ])
  end

  it ".failed_deliveries with max page" do
    time = Time.now
    app_client = instance_double(Octokit::Client)
    expect(described_class).to receive(:app_client).and_return(app_client)
    expect(app_client).to receive(:get).with("/app/hook/deliveries?per_page=100").and_return([
      {guid: "3", status: "Fail", delivered_at: time + 3}
    ])
    expect(app_client).to receive(:last_response).and_return(instance_double(Sawyer::Response, rels: {next: instance_double(Sawyer::Relation, href: "next_url")}))
    expect(Clog).to receive(:emit).with("failed deliveries page limit reached").and_call_original
    expect(Clog).to receive(:emit).with("fetched deliveries").and_call_original
    failed_deliveries = described_class.failed_deliveries(time, 1)
    expect(failed_deliveries).to eq([{guid: "3", status: "Fail", delivered_at: time + 3}])
  end

  it ".redeliver_failed_deliveries" do
    time = Time.now
    app_client = instance_double(Octokit::Client)
    expect(described_class).to receive(:app_client).and_return(app_client)
    expect(described_class).to receive(:failed_deliveries).with(time).and_return([{id: "1"}, {id: "2"}])
    expect(app_client).to receive(:post).with("/app/hook/deliveries/1/attempts")
    expect(app_client).to receive(:post).with("/app/hook/deliveries/2/attempts")
    described_class.redeliver_failed_deliveries(time)
  end
end
