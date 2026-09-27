# frozen_string_literal: true

# Creating a Postgres ember: an Ember plus the row that makes it a database.
#
# Everything else -- placement, resume, pause -- is EmberOperations, because
# none of it depends on what runs inside. What is here is the part that does:
# picking a Postgres template, minting the superuser password, and the claim
# token for a database handed to somebody who has no account yet.
module PostgresEmberOperations
  module_function

  WORKLOAD = "postgres"

  # Returns the PostgresEmber, running; its Ember is reachable through #ember.
  def create(project_id:, location:, name: nil, pg_version: "18", database: "postgres",
    creator_ip: nil, expires_at: nil, claim_token: nil)
    ember = EmberOperations.create(project_id:, location:, workload: WORKLOAD, version: pg_version,
      name:, expires_at:) do |ember|
      PostgresEmber.create_with_id(
        ember.id,
        pg_version:, database_name: database,
        superuser_password: SecureRandom.urlsafe_base64(24),
        creator_ip:,
        claim_token_digest: claim_token && PostgresEmber.hash_claim_token(claim_token),
      )
    end
    PostgresEmber[ember.id]
  end
end
