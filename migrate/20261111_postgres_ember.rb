# frozen_string_literal: true

Sequel.migration do
  change do
    # The Postgres side of an ember: what an ember has to know to be a database
    # rather than just a micro-VM.
    #
    # It shares the ember's primary key rather than carrying one of its own, in
    # the way host_provider shares a host's: a PostgresEmber is an Ember, it cannot
    # exist without one, and the ember cannot be repointed at a different
    # database. That also keeps the ubid a tenant sees the same on both.
    create_table(:postgres_ember) do
      foreign_key :id, :ember, type: :uuid, primary_key: true, on_delete: :cascade
      column :pg_version, :text, collate: '"C"', null: false, default: "18"
      # Encrypted at the application layer.
      column :superuser_password, :text, collate: '"C"', null: false
      column :database_name, :text, collate: '"C"', null: false, default: "postgres"

      # Try-before-you-sign-up: an anonymous ember is claimed into a project
      # with a single-use token. The token is stored as a digest so that a
      # database leak does not hand over every unclaimed database, and the
      # address is kept to rate-limit whoever is creating them. None of this
      # is meaningful for a workload nobody is invited to claim, which is why
      # it sits here rather than on ember.
      column :claim_token_digest, :text, collate: '"C"'
      column :claimed_at, :timestamptz
      column :creator_ip, :inet
    end
  end
end
