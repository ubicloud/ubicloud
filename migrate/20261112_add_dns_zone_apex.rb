# frozen_string_literal: true

Sequel.migration do
  change do
    label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
    hostname = "#{label}(\\.#{label})+\\.?"
    local_part = "[a-z0-9_+-]+"

    alter_table(:dns_zone) do
      add_column :apex_nameservers, "text[]", collate: '"C"'
      add_column :soa_email, :text, collate: '"C"'
      add_constraint(:apex_nameservers_not_empty) { cardinality(apex_nameservers) > 0 }
      add_constraint(:apex_nameservers_hostnames, "array_position(apex_nameservers, NULL) IS NULL AND array_to_string(apex_nameservers, '') !~ ' ' AND array_to_string(apex_nameservers, ' ') ~* '^#{hostname}( #{hostname})*$'")
      add_constraint(:soa_email_format, "soa_email ~* '^#{local_part}(\\.#{local_part})*@#{label}(\\.#{label})+$'")
    end
  end
end
