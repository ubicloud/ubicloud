# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:hypervisor) do
      column :id, :uuid, primary_key: true
      column :name, :text, collate: '"C"', null: false
      column :version, :text, collate: '"C"', null: true
      constraint(:hypervisor_name_check, name: %w[ch qemu])
      unique [:name, :version]
    end

    from(:hypervisor).import([:id, :name, :version],
      [
        ["ffffffff-ff00-81da-87fe-08f80c88ca10", "ch", "35.1"], # etzzzzzzzz021gzz0hy0ch3510
        ["ffffffff-ff00-81da-87fe-08f80c890c00", "ch", "46.0"], # etzzzzzzzz021gzz0hy0ch4600
        ["ffffffff-ff00-81da-87fe-08f80c894600", "ch", "53.0"], # etzzzzzzzz021gzz0hy0ch5301
        ["ffffffff-ff00-81da-87ff-f047c0bba9b0", "qemu", nil], # etzzzzzzzz021gzzz0hy0qemv1
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
