# frozen_string_literal: true

class UbiCli
  on("pg", "ember", "claim") do
    desc "Claim an anonymous PostgreSQL ember into this project"

    banner "ubi pg ember claim claim-token"

    args 1

    run do |claim_token|
      logged_argv[-1] = "-"
      ember = sdk.postgres.claim_ember(claim_token)
      response("Claimed PostgreSQL ember with id: #{ember.id}")
    end
  end
end
