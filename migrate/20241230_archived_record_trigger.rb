# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      CREATE FUNCTION archived_record_insert() RETURNS TRIGGER LANGUAGE plpgsql AS $$
        BEGIN
          INSERT INTO archived_record (model_name, model_values) VALUES (TG_ARGV[0], to_jsonb(OLD));
          RETURN NEW;
        END;
      $$
    SQL

    %w[subject action object].each do |tag_type|
      run <<~SQL
        CREATE TRIGGER archived_record_insert AFTER DELETE ON applied_#{tag_type}_tag
        FOR EACH ROW EXECUTE FUNCTION archived_record_insert('applied_#{tag_type}_tag')
      SQL
    end
  end

  down do
    %w[subject action object].each do |tag_type|
      run "DROP TRIGGER archived_record_insert ON applied_#{tag_type}_tag"
    end

    run "DROP FUNCTION archived_record_insert()"
  end
end
