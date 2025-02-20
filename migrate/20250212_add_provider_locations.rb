# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:provider_name) do
      column :name, :text, null: false, primary_key: true
    end
    create_table(:provider_location) do
      column :id, :uuid, primary_key: true
      column :display_name, String, null: false
      column :internal_name, String, null: false
      column :ui_name, String, null: false
      column :visible, :boolean, null: false
      foreign_key :provider_name, :provider_name, type: :text, null: false
    end

    run <<~SQL
    INSERT INTO provider_name (name) VALUES ('hetzner'), ('leaseweb'), ('latitude'), ('global');
    INSERT INTO provider_location (provider_name, display_name, internal_name, ui_name, visible, id) VALUES
      ('hetzner', 'eu-central-h1', 'hetzner-fsn1', 'Germany', true, 'f2f4b780-989e-86c1-a870-6a91520bc628'),
      ('hetzner', 'eu-north-h1', 'hetzner-hel1', 'Finland', true, '7103a5a6-ca75-8ec1-a813-608194763c08'),
      ('hetzner', 'github-runners', 'github-runners', 'GithubRunner', false, '09099f58-1245-8ec1-98c1-e3565d143c31'),
      ('hetzner', 'hetzner-ai', 'hetzner-ai', 'hetzner-ai', false, '484f5b98-3619-8ec1-b3c5-d17bbbc06ff9'),
      ('leaseweb', 'us-east-a2', 'leaseweb-wdc02', 'Virginia, US', true, '54b35dc4-081b-8ec1-91f8-b7e41801bce9'),
      ('latitude', 'eu-central-a1', 'latitude-fra', 'Germany (Latitude)', false, 'cb2bf85a-075f-8ec1-a4ae-8e219441f62e'),
      ('latitude', 'latitude-ai', 'latitude-ai', 'latitude-ai', false, '970f0525-fce8-8ac1-b9cc-c19f04713d61')
      ON CONFLICT DO NOTHING;
    SQL
  end

  down do
    drop_table(:provider_location)
    drop_enum(:provider_name)
  end
end
