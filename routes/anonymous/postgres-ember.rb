# frozen_string_literal: true

# The anonymous ember surface (design doc 7.5).
#
# An ember is meant to be obtainable without an account, so this runs ahead
# of the authentication pipeline: there is no personal access token to
# present. What stands in for one is a token minted at create time and
# returned once, and a per-address limit on how many embers a day one
# source can create.
#
# Anonymous embers belong to the service project until somebody claims one
# into their own, which is what the token is for. It is the same token that
# authenticates management here, so claiming an ember ends anonymous access
# to it: the claim clears the digest and rotates the password.
class Clover
  hash_branch(:anonymous_prefix, "postgres-ember") do |r|
    unless Config.ember_service_project_id
      fail CloverError.new(501, "NotImplemented", "Anonymous embers are not enabled")
    end

    r.post true do
      anonymous_postgres_ember_create
    end

    r.on :ubid_uuid do |id|
      ember = PostgresEmber[id]
      # An ember somebody has already claimed is not on this surface any
      # more, and saying so would tell an unauthenticated caller it exists.
      unless ember && ember.project_id == Config.ember_service_project_id &&
          ember.claim_token_matches?(anonymous_postgres_ember_token)
        fail CloverError.new(404, "ResourceNotFound", "No such ember")
      end

      r.post %w[pause resume reset-password].freeze do |action|
        no_audit_log
        postgres_ember_action(ember, action)
      end

      r.is do
        r.get do
          anonymous_postgres_ember_response(ember)
        end

        r.delete do
          no_audit_log
          ember.incr_destroy
          204
        end
      end
    end

    404
  end
end
