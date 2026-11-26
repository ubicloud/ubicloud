# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:ipv4_address) do
      add_column :assigned, :boolean, null: false, default: false
    end

    # assigned is true when assigned_vm_address has the address, the same
    # test as its unique key on ip. Triggers keep it so when rows are
    # written to either table. Each trigger reads the other table from its
    # own snapshot, so an assignment that commits while its subnet is being
    # populated can be missed. No code does that: the allocator assigns
    # only addresses it read from committed rows.
    run <<~SQL
      CREATE FUNCTION ipv4_address_assigned_by_vm_address() RETURNS TRIGGER LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP IN ('UPDATE', 'DELETE') THEN
            UPDATE ipv4_address SET assigned = false WHERE ip = OLD.ip;
          END IF;
          IF TG_OP IN ('INSERT', 'UPDATE') THEN
            UPDATE ipv4_address SET assigned = true WHERE ip = NEW.ip;
          END IF;
          RETURN NULL;
        END;
      $$
    SQL

    run <<~SQL
      CREATE TRIGGER ipv4_address_assigned
      AFTER INSERT OR DELETE OR UPDATE OF ip ON assigned_vm_address
      FOR EACH ROW EXECUTE FUNCTION ipv4_address_assigned_by_vm_address()
    SQL

    run <<~SQL
      CREATE FUNCTION ipv4_address_assigned_on_insert() RETURNS TRIGGER LANGUAGE plpgsql AS $$
        BEGIN
          NEW.assigned := EXISTS (SELECT 1 FROM assigned_vm_address WHERE ip = NEW.ip);
          RETURN NEW;
        END;
      $$
    SQL

    run <<~SQL
      CREATE TRIGGER ipv4_address_assigned
      BEFORE INSERT ON ipv4_address
      FOR EACH ROW EXECUTE FUNCTION ipv4_address_assigned_on_insert()
    SQL

    # Creating the trigger on assigned_vm_address waits for writes to it in
    # progress, and blocks new ones until this migration commits, as adding
    # the column did for ipv4_address. So this update sees every assignment
    # that the triggers do not.
    run "UPDATE ipv4_address SET assigned = true WHERE ip IN (SELECT ip FROM assigned_vm_address)"
  end

  down do
    run "DROP TRIGGER ipv4_address_assigned ON ipv4_address"
    run "DROP FUNCTION ipv4_address_assigned_on_insert()"
    run "DROP TRIGGER ipv4_address_assigned ON assigned_vm_address"
    run "DROP FUNCTION ipv4_address_assigned_by_vm_address()"

    alter_table(:ipv4_address) do
      drop_column :assigned
    end
  end
end
