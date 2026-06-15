# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:cert) do
      # When set, the ACME DNS-01 challenge is written at this name in the cert's
      # dns_zone (a delegation zone) instead of at _acme-challenge.<hostname>.
      # Lets us issue certs for domains whose DNS we don't control, via a
      # user-created CNAME from _acme-challenge.<domain> to this name.
      add_column :acme_dns_name, :text
    end
  end
end
