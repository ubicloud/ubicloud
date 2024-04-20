# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      UPDATE access_policy
      SET body = (regexp_replace(body::text, 'hetzner-hel1', 'eu-north-h1', 'g'))::jsonb;

      UPDATE access_policy
      SET body = (regexp_replace(body::text, 'hetzner-fsn1', 'eu-central-h1', 'g'))::jsonb;

      UPDATE access_tag
      SET name = (regexp_replace(name, 'hetzner-hel1', 'eu-north-h1'));

      UPDATE access_tag
      SET name = (regexp_replace(name, 'hetzner-fsn1', 'eu-central-h1'));
    SQL
  end

  down do
    run <<~SQL
      UPDATE access_policy
      SET body = (regexp_replace(body::text, 'eu-north-h1', 'hetzner-hel1', 'g'))::jsonb;

      UPDATE access_policy
      SET body = (regexp_replace(body::text, 'eu-central-h1', 'hetzner-fsn1', 'g'))::jsonb;

      UPDATE access_tag
      SET name = (regexp_replace(name, 'eu-north-h1', 'hetzner-hel1'));

      UPDATE access_tag
      SET name = (regexp_replace(name, 'eu-central-h1', 'hetzner-fsn1'));
    SQL
  end
end
