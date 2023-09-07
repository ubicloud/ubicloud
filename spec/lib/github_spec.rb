# frozen_string_literal: true

RSpec.describe Github do
  it "creates oauth client" do
    expect(Octokit::Client).to receive(:new).with(client_id: Config.github_app_client_id, client_secret: Config.github_app_client_secret)

    described_class.oauth_client
  end

  it "creates app client" do
    expect(Config).to receive(:github_app_id).and_return("123456")
    private_key = instance_double(OpenSSL::PKey::RSA)
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
    expect(Octokit::Client).to receive(:new).with(access_token: "abcdefg")

    described_class.installation_client(installation_id)
  end
end
