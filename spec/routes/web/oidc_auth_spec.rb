# frozen_string_literal: true

require_relative "spec_helper"
require "jwt"
require "cgi/escape"

# Rack middleware acting as a fake OIDC authorization server.
# Intercepts GET /fake_oidc/authorize, captures the nonce for later use,
# and redirects to the callback URL with configurable response modes.
class FakeOidcApp
  attr_accessor :last_nonce, :callback_mode

  def initialize(main_app)
    @main_app = main_app
    @last_nonce = nil
    @callback_mode = :success
  end

  def call(env)
    req = Rack::Request.new(env)
    return authorize(req) if req.path_info == "/fake_oidc/authorize"
    @main_app.call(env)
  end

  private

  def authorize(req)
    @last_nonce = req.params["nonce"]
    state = CGI.escape(req.params["state"].to_s)
    redirect_uri = req.params["redirect_uri"]
    sep = redirect_uri.include?("?") ? "&" : "?"

    location = case @callback_mode
    when :error
      "error=access_denied"
    when :error_with_uri
      "error=access_denied&error_description=User+denied&error_uri=#{CGI.escape("http://help.example.com")}"
    when :error_reason
      "error_reason=server_error&error_description=Internal+error"
    when :no_code
      "state=#{state}"
    when :wrong_state
      "code=testcode&state=wrongstate"
    else
      "code=testcode&state=#{state}"
    end

    [302, {"Location" => "#{redirect_uri}#{sep}#{location}", "Content-Type" => "text/html"}, []]
  end

  APP = new(RACK_TEST_APP)
end

RSpec.describe Clover, "OIDC auth" do
  let(:fake_oidc) { FakeOidcApp::APP }

  let(:oidc_provider) do
    op = OidcProvider.create(
      display_name: "TestOIDC",
      client_id: "client_id_test",
      client_secret: "client_secret_test",
      url: "http://www.example.com",
      authorization_endpoint: "/fake_oidc/authorize",
      token_endpoint: "/fake_oidc/token",
      userinfo_endpoint: "/fake_oidc/userinfo",
      jwks_uri: "http://www.example.com/fake_oidc/jwks",
    )
    op.add_allowed_domain("Example.com")
    op
  end

  let(:token_url) { "http://www.example.com/fake_oidc/token" }
  let(:userinfo_url) { "http://www.example.com/fake_oidc/userinfo" }

  before do
    OmniAuth.config.logger = Logger.new(IO::NULL)
    OmniAuth.config.test_mode = false
    Capybara.app = fake_oidc
    fake_oidc.last_nonce = nil
    fake_oidc.callback_mode = :success
    allow(Config).to receive(:base_url).and_return("http://www.example.com")
  end

  after do
    OmniAuth.config.test_mode = true
    Capybara.app = RACK_TEST_APP
  end

  def generate_id_token(nonce:, iss: "http://www.example.com", aud: "client_id_test", sub: "oidc_sub_123", email: "user@example.com", array_wrap: false, **)
    time = Time.now.to_i
    payload = {iss:, aud:, sub:, email:, nonce:, iat: time, exp: time + 3600, **}.transform_keys!(&:to_s)
    payload.compact!
    payload = [payload] if array_wrap
    JWT.encode(payload, nil, "none")
  end

  # Stubs the OIDC token endpoint via WebMock.
  def stub_token_endpoint(token_type: "bearer", id_token: {}, **)
    stub_request(:post, token_url).to_return do |_req|
      body = {access_token: "access_tok", token_type:, expires_in: 3600, **}.transform_keys!(&:to_s)

      case id_token
      when Hash
        body["id_token"] = generate_id_token(nonce: fake_oidc.last_nonce, **id_token)
      when String
        body["id_token"] = id_token
      end

      {status: 200, body: body.to_json, headers: {"Content-Type" => "application/json"}}
    end
  end

  def stub_userinfo_endpoint(body: {"sub" => "oidc_sub_123", "email" => "user@example.com"})
    stub_request(:get, userinfo_url).to_return(
      status: 200, body: body.to_json, headers: {"Content-Type" => "application/json"},
    )
  end

  def initiate_oidc_login
    visit "/auth/#{oidc_provider.ubid}"
    click_button "Login"
  end

  it "fails login if domain is not allowed domain for OidcProvider" do
    oidc_provider.remove_allowed_domain("example.com")
    stub_token_endpoint
    stub_userinfo_endpoint
    initiate_oidc_login

    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("Login via TestOIDC is not allowed for the example.com domain.")
    account = Account.first
    expect(account.email).to eq("user@example.com")
    # Creation of identity still allowed, just not login
    expect(AccountIdentity.select_map([:account_id, :provider])).to eq([[account.id, oidc_provider.ubid]])

    visit "/"
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_current_path "/login", ignore_query: true
  end

  it "performs full OIDC login creating account (string aud, no email_verified, no groups)" do
    stub_token_endpoint
    stub_userinfo_endpoint
    initiate_oidc_login

    expect(page.title).to eq("Ubicloud - Default Dashboard")
    expect(page).to have_flash_notice("You have been logged in")
    account = Account.first
    expect(account.email).to eq("user@example.com")
    expect(AccountIdentity.select_map([:account_id, :provider])).to eq([[account.id, oidc_provider.ubid]])
  end

  it "handles array aud in id_token (aud.is_a?(String) false branch)" do
    stub_token_endpoint(id_token: {aud: ["client_id_test"]})
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Default Dashboard")
  end

  it "handles email_verified present in id_token" do
    stub_token_endpoint(id_token: {email_verified: true})
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Default Dashboard")
  end

  it "handles non-hash JWT payload (token.is_a?(Hash) false branch)" do
    stub_token_endpoint(id_token: {array_wrap: true})
    stub_userinfo_endpoint(body: {})

    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  describe "with group_prefix configured" do
    before { oidc_provider.update(group_prefix: "org-") }

    it "extracts groups from id_token without calling userinfo endpoint" do
      stub_token_endpoint(id_token: {groups: %w[eng ops]})
      initiate_oidc_login
      expect(page.title).to eq("Ubicloud - Default Dashboard")
      visit "/oidc-groups"
      expect(page.body).to eq "org-eng,org-ops"
    end

    it "issues userinfo call when groups not in id_token" do
      stub_token_endpoint  # generates id_token with sub+email but no groups
      stub_userinfo_endpoint(body: {"sub" => "oidc_sub_123", "email" => "user@example.com", "groups" => %w[foo bar]})
      initiate_oidc_login
      expect(page.title).to eq("Ubicloud - Default Dashboard")
      visit "/oidc-groups"
      expect(page.body).to eq "org-foo,org-bar"
    end

    it "handles userinfo call not including information that was in id token" do
      stub_token_endpoint(id_token: {email_verified: true})
      stub_userinfo_endpoint(body: {"groups" => %w[foo bar]})
      initiate_oidc_login
      expect(page.title).to eq("Ubicloud - Default Dashboard")
      visit "/oidc-groups"
      expect(page.body).to eq "org-foo,org-bar"
    end
  end

  it "handles error param in callback (params['error'] branch, no error_reason)" do
    fake_oidc.callback_mode = :error
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles error_reason param with error_description in callback (params['error_reason'] branch)" do
    fake_oidc.callback_mode = :error_reason
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles error with error_uri (CallbackError message with all three fields)" do
    fake_oidc.callback_mode = :error_with_uri
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles nil session state when callback visited without request_phase" do
    # No request_phase → session has no omniauth.state → expected_state.nil? true
    visit "/auth/#{oidc_provider.ubid}/callback?code=testcode&state=somestate"
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles state mismatch in callback (expected_state not nil, params state wrong)" do
    fake_oidc.callback_mode = :wrong_state
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles missing code in callback" do
    fake_oidc.callback_mode = :no_code
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles non-bearer token type from token endpoint" do
    stub_token_endpoint(token_type: "mac")
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles nil token_type in token response (&. nil branch)" do
    stub_token_endpoint(token_type: nil)
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles absent id_token in token response" do
    stub_token_endpoint(id_token: nil)
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles invalid issuer in id_token (iss mismatch, short-circuits || chain)" do
    stub_token_endpoint(id_token: {iss: "http://evil.example.com"})
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles invalid audience in id_token (iss ok, aud mismatch)" do
    stub_token_endpoint(id_token: {aud: "wrong_client_id"})
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles invalid nonce in id_token (iss and aud ok, nonce mismatch)" do
    stub_token_endpoint(id_token: {nonce: "wrong_nonce"})
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles id_token without email, but email in userinfo" do
    stub_token_endpoint(id_token: {email: nil})
    stub_userinfo_endpoint
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Default Dashboard")
  end

  it "handles id_token without email, and email not in userinfo" do
    stub_token_endpoint(id_token: {email: nil})
    stub_userinfo_endpoint(body: {})
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("Social login is only allowed if social login provider provides email")
  end

  it "handles Excon::Error from token endpoint" do
    stub_request(:post, token_url).to_raise(Excon::Error.new("Connection failed"))
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles JWT::DecodeError from malformed id_token" do
    stub_token_endpoint(id_token: "not_a_valid_jwt")
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles Errno::ETIMEDOUT from token endpoint" do
    stub_request(:post, token_url).to_raise(Errno::ETIMEDOUT.new("Connection timed out"))
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "handles SocketError from token endpoint" do
    stub_request(:post, token_url).to_raise(SocketError.new("Failed to connect"))
    initiate_oidc_login
    expect(page.title).to eq("Ubicloud - Login")
    expect(page).to have_flash_error("There was an error logging in with the external provider")
  end

  it "appends redirect_uri to callback URL when redirect_uri param is present in OIDC request" do
    stub_token_endpoint

    # Visit the auth page to establish session and obtain a CSRF token from the form
    visit "/auth/#{oidc_provider.ubid}"
    csrf_token = find("input[name='_csrf']", visible: false).value

    # POST with redirect_uri and CSRF token; process_and_follow_redirects follows the full
    # authorize → fake OIDC → callback → dashboard redirect chain automatically.
    page.driver.browser.process_and_follow_redirects(
      :post,
      "/auth/#{oidc_provider.ubid}",
      "_csrf" => csrf_token, "redirect_uri" => "http://example.com/after-auth",
    )

    expect(Account.count).to eq 1
    expect(page.title).to eq("Ubicloud - Default Dashboard")
  end

  describe OmniAuth::Strategies::Oidc::CallbackError do
    it "formats message with all three fields" do
      error = described_class.new(error: "access_denied", reason: "User denied", uri: "http://help.example.com")
      expect(error.message).to eq("access_denied | User denied | http://help.example.com")
    end

    it "formats message with only error when reason and uri are nil" do
      error = described_class.new(error: "access_denied", reason: nil, uri: nil)
      expect(error.message).to eq("access_denied")
    end
  end
end
