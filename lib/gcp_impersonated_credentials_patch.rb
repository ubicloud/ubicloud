# frozen_string_literal: true

require "googleauth"
require "googleauth/impersonated_service_account"

# Backport of https://github.com/googleapis/google-auth-library-ruby/pull/556
# (unreleased): prepare_auth_header returns the hash it passed to
# @source_credentials.updater_proc, but BaseClient#updater_proc populates a
# CLONE of it, so impersonation requests go out with no Authorization header
# (401 CREDENTIALS_MISSING under GKE Workload Identity). Return
# updater_proc's result instead.
#
# Remove this file (and its require in model/location_credential_gcp.rb)
# once we upgrade to a googleauth release that includes that PR.
module GcpImpersonatedCredentialsPatch
  module PrepareAuthHeaderFix
    def prepare_auth_header
      auth_header = {}
      @source_credentials.updater_proc.call auth_header
    end
  end
end

Google::Auth::ImpersonatedServiceAccountCredentials.prepend(GcpImpersonatedCredentialsPatch::PrepareAuthHeaderFix)
