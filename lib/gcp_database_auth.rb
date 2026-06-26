# frozen_string_literal: true

require "sequel"
require "uri"
require "time"

module GcpDatabaseAuth
  SCOPE = "https://www.googleapis.com/auth/sqlservice.login"
  SA_SUFFIX = ".gserviceaccount.com"

  class Error < StandardError; end

  @mutex = Mutex.new
  @cache_hash = {}      # sa_email => [token, expires_at_monotonic]
  @sa_mutexes = {}      # sa_email => Mutex (serializes minting for that SA)

  class << self
    def reset_cache!
      @mutex.synchronize do
        @cache_hash.clear
        @sa_mutexes.clear
      end
    end

    def access_token(service_account:)
      # Fast path: a still-valid cached token, taken under the global lock only.
      cached = cached_token(service_account)
      return cached if cached

      # Slow path: serialize minting per SA so the network call runs under the
      # per-SA lock, not the global one — a refresh blocks neither other SAs nor
      # valid cached reads. The double-check returns the token a concurrent
      # caller already cached instead of minting a second time.
      sa_mutex = @mutex.synchronize { @sa_mutexes[service_account] ||= Mutex.new }
      sa_mutex.synchronize do
        cached = cached_token(service_account)
        return cached if cached
        token, ttl = mint_impersonated(service_account)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @mutex.synchronize { @cache_hash[service_account] = [token, now + ttl] }
        token
      end
    end

    private

    # A still-valid cached token for the SA (> 5 minutes to expiry), else nil.
    # Reads the cache under the global lock and never does I/O.
    def cached_token(service_account)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @mutex.synchronize do
        token, exp = @cache_hash[service_account]
        token if token && now < (exp - 300)
      end
    end

    def mint_impersonated(sa_email)
      require "googleauth"
      require "google/apis/iamcredentials_v1"
      svc = Google::Apis::IamcredentialsV1::IAMCredentialsService.new
      svc.authorization = Google::Auth.get_application_default(["https://www.googleapis.com/auth/cloud-platform"])
      req = Google::Apis::IamcredentialsV1::GenerateAccessTokenRequest.new(scope: [SCOPE], lifetime: "3600s")
      resp = svc.generate_service_account_access_token("projects/-/serviceAccounts/#{sa_email}", req)
      [resp.access_token, Time.parse(resp.expire_time) - Time.now]
    rescue Google::Apis::Error => e
      # The top-line message ("Invalid request") hides the real reason; the
      # response body carries the INVALID_ARGUMENT/PERMISSION detail. Surface
      # both, plus the SA we tried to impersonate, while preserving the original
      # backtrace so the failing call site stays visible in production.
      raise e.class, "generateAccessToken for #{sa_email.inspect} failed: #{e.message}: #{e.body}", e.backtrace
    end
  end

  # The CloudSQL IAM db username for a service account: the SA email minus its
  # .gserviceaccount.com suffix. Used by the hook as the libpq login user.
  def self.db_user_for(sa) = sa.delete_suffix(SA_SUFFIX)

  # The Postgres role from the connection URL. Delegates to Sequel's own parser
  # so the result always matches opts[:user] — userinfo or ?user= query param,
  # percent-decoded. options_from_uri is a private class method (Sequel exposes
  # no public URI->options parser), hence send.
  def self.url_user(url)
    Sequel::Database.send(:options_from_uri, URI.parse(url))[:user]
  end

  # Switch the active role at startup to back what was in the original opts
  def self.role_connect_option(role)
    return nil if role.nil? || role.empty?
    raise ArgumentError, "invalid role identifier: #{role.inspect}" unless role.match?(/\A[a-z_][a-z0-9_]*\z/)
    "-c role=#{role}"
  end

  # Prepended onto Sequel::Postgres::Database. For a connection carrying the
  # role->SA map in its driver_options, the connection's :user names the desired
  # role: impersonate that role's SA for the token (password), connect as the SA's
  # db username, and switch the active role via the native option. Connections without the
  # map pass through untouched.
  module ServerOptsInjection
    def server_opts(server)
      opts = super
      map = opts.dig(:driver_options, :gcp_cloudsql_iam_sa_by_role)
      return opts unless map

      role = opts[:user]
      service_account = map[role]
      raise Error, "no CloudSQL IAM SA mapped for role #{role.inspect}" unless service_account

      opts = opts.dup
      driver_options = opts[:driver_options].dup
      driver_options.delete(:gcp_cloudsql_iam_sa_by_role)
      opts[:user] = GcpDatabaseAuth.db_user_for(service_account)
      opts[:password] = GcpDatabaseAuth.access_token(service_account:)
      # role is the connection's user (a matched map key, always present), so
      # role_connect_option returns the option string here
      opts[:driver_options] = driver_options.merge(options: GcpDatabaseAuth.role_connect_option(role))
      opts
    end
  end
end

# Activate the injection. load_adapter ensures Sequel::Postgres::Database exists
# even though db.rb only requires "sequel/core" (adapters are otherwise lazy) —
# a bare `if defined?` guard would silently skip the prepend at this point and
# the token would never be injected. The prepend is marker-gated, so it is inert
# on connections without the role->SA map (incl. all customer-DB connections).
Sequel::Database.load_adapter(:postgres)
Sequel::Postgres::Database.prepend(GcpDatabaseAuth::ServerOptsInjection)
