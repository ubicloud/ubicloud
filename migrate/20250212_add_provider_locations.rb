# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:provider) do
      column :name, :text, primary_key: true
    end
    create_table(:location) do
      column :id, :uuid, primary_key: true
      column :display_name, String, null: false
      column :name, String, null: false
      column :ui_name, String, null: false
      column :visible, :boolean, null: false
      foreign_key :provider, :provider, type: :text, null: false
    end

    run <<~SQL
      INSERT INTO provider (name) VALUES ('hetzner'), ('leaseweb'), ('latitude'), ('global');
    SQL

    run <<~SQL
    INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
      -- ubid: p1ybtbf04rkt3n1r6n4aj1f32h
      ('hetzner', 'eu-central-h1', 'hetzner-fsn1', 'Germany', true, 'caa7a807-36c5-8420-a75c-f906839dad71'),
      -- ubid: p1e41tb9paep6n09p10cmery0h
      ('hetzner', 'eu-north-h1', 'hetzner-hel1', 'Finland', true, '1f214853-0bc4-8020-b910-dffb867ef44f'),
      -- ubid: p1144syp0j8p7k30y6njx2gy33
      ('hetzner', 'github-runners', 'github-runners', 'GithubRunner', false, '6b9ef786-b842-8420-8c65-c25e3d4bdf3d'),
      -- ubid: p1917nq61p367pf2x2yxvr1qzk
      ('hetzner', 'hetzner-ai', 'hetzner-ai', 'hetzner-ai', false, '839acf48-8bf0-8820-8c98-3fd4c231a6cb'),
      -- ubid: p1ajsnvh083e6j7wbfs0r06yek
      ('leaseweb', 'us-east-a2', 'leaseweb-wdc02', 'Virginia, US', true, 'e0865080-9a3d-8020-a812-f5817c7afe7f'),
      -- ubid: p1scnzgpg7by6mjq8w8cm87v2x
      ('latitude', 'eu-central-a1', 'latitude-fra', 'Germany (Latitude)', false, '423ffc98-d991-8420-9a6b-378337c21fb1'),
      -- ubid: p1jw7ga9fwx24q76c37r4e4yp3
      ('latitude', 'latitude-ai', 'latitude-ai', 'latitude-ai', false, '55f02004-8448-8420-9b37-ccd96b5c2e50')
      ON CONFLICT DO NOTHING;
    SQL
  end

  down do
    drop_table(:location)
    drop_table(:provider)
  end
end
