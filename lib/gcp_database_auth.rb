# frozen_string_literal: true

require "googleauth"
require "google/apis/iamcredentials_v1"

module GcpDatabaseAuth
  class Error < StandardError; end

  @mutex = Mutex.new
  @cache = {} # sa_email => [token, refresh_deadline_monotonic]

  class << self
    def connect_opts_proc(sa_by_role)
      lambda do |opts|
        role = opts[:user]
        service_account = sa_by_role[role]
        raise Error, "no CloudSQL IAM SA mapped for role #{role.inspect}" unless service_account
        # The CloudSQL IAM db username is the SA email minus its .gserviceaccount.com suffix.
        opts[:user] = service_account.delete_suffix(".gserviceaccount.com")
        opts[:password] = access_token(service_account)
        opts[:driver_options] = opts[:driver_options].merge(options: role_connect_option(role))
      end
    end

    # The Postgres role from the connection URL. Delegates to Sequel's own parser
    # so the result always matches opts[:user] — userinfo or ?user= query param,
    # percent-decoded. options_from_uri is a private class method (Sequel exposes
    # no public URI->options parser), hence send.
    def url_user(url)
      Sequel::Database.send(:options_from_uri, URI.parse(url))[:user]
    end

    private

    def reset_cache!
      @mutex.synchronize { @cache.clear }
    end

    # A cached token for the SA while it stays more than 5 minutes from expiry,
    # else a freshly minted one. Minting holds the lock: a refresh happens about
    # once an hour per SA, and holding the lock across it keeps concurrent
    # connections from minting twice.
    def access_token(service_account)
      @mutex.synchronize do
        token, refresh_deadline = @cache[service_account]
        unless token && Process.clock_gettime(Process::CLOCK_MONOTONIC) < refresh_deadline
          token, ttl = mint_impersonated(service_account)
          @cache[service_account] = [token, Process.clock_gettime(Process::CLOCK_MONOTONIC) + ttl - 300]
        end
        token
      end
    end

    # libpq options value that SETs the active role at connection startup. nil for
    # a blank role; a bare identifier is validated (fail-closed) otherwise.
    def role_connect_option(role)
      return nil if role.nil? || role.empty?
      raise ArgumentError, "invalid role identifier: #{role.inspect}" unless role.match?(/\A[a-z_][a-z0-9_]*\z/)
      "-c role=#{role}"
    end

    def mint_impersonated(sa_email)
      svc = Google::Apis::IamcredentialsV1::IAMCredentialsService.new
      svc.authorization = Google::Auth.get_application_default(["https://www.googleapis.com/auth/cloud-platform"])
      req = Google::Apis::IamcredentialsV1::GenerateAccessTokenRequest.new(scope: ["https://www.googleapis.com/auth/sqlservice.login"], lifetime: "3600s")
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
end
