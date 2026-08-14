# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:hypervisor) do
      column :id, :uuid, primary_key: true
      column :name, :text, collate: '"C"', unique: true
    end

    from(:hypervisor).import([:name, :id],
      [
        ["Cloud Hypervisor 35.1", "ffffffff-ff00-81da-87ff-f047c0644650"], # etzzzzzzzz021gzzz0hy0ch350
        ["Cloud Hypervisor 46.0", "ffffffff-ff00-81da-87ff-f047c0644860"], # etzzzzzzzz021gzzz0hy0ch461
        ["Cloud Hypervisor 53.0", "ffffffff-ff00-81da-87ff-f047c0644a30"], # etzzzzzzzz021gzzz0hy0ch530
        ["Qemu", "ffffffff-ff00-81da-87ff-f047c0bba9b0"], # etzzzzzzzz021gzzz0hy0qemv1
      ])

    alter_table(:vm) do
      add_foreign_key :hypervisor_id, :hypervisor, type: :uuid
    end
  end

  down do
    alter_table(:vm) do
      drop_foreign_key :hypervisor_id, type: :uuid
    end

    drop_table(:hypervisor)
  end
end
