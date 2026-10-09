# frozen_string_literal: true

Sequel.migration do
  id = "aaf75cb9-3962-8020-8c2a-41f3644551cf"

  up do
    run <<~SQL
      INSERT INTO location (provider, display_name, name, ui_name, visible, id) VALUES
        -- us-west-u1-dedicated (UBID: 10nbvnse9sca0hgn43wv48n8wz)
        ('ubicloud', 'us-west-u1-dedicated', 'us-west-u1-dedicated', 'SF Bay Area, US (Dedicated)', false, '#{id}');
    SQL

    from(:strand).insert(id:, prog: "LocationNexus", label: "wait")
  end

  down do
    from(:strand).where(id:).delete
    from(:location).where(id:).delete
  end
end
