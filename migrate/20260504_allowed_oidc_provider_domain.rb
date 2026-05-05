# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:allowed_oidc_provider_domain) do
      foreign_key :oidc_provider_id, :oidc_provider, type: :uuid
      citext :domain, collate: '"C"'
      primary_key [:oidc_provider_id, :domain]
    end
  end
end
