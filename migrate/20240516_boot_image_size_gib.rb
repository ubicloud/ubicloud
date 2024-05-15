# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:boot_image) do
      add_column :size_gib, Integer, null: true
    end

    # Update existing boot images
    run <<-SQL
    UPDATE boot_image
    SET size_gib = CASE
        WHEN boot_image.name = 'ubuntu-jammy' THEN 3
        WHEN boot_image.name = 'almalinux-9.1' THEN 10
        WHEN vm_host.arch = 'x64' AND boot_image.name LIKE 'github-ubuntu-%' THEN 75
        WHEN vm_host.arch = 'arm64' AND boot_image.name LIKE 'github-ubuntu-%' THEN 50
        WHEN boot_image.name = 'github-gpu-ubuntu-2204' THEN 31
        WHEN boot_image.name LIKE 'postgres-%' THEN 8
        ELSE 0
    END
    FROM vm_host
    WHERE boot_image.vm_host_id = vm_host.id;
    SQL

    alter_table(:boot_image) do
      set_column_not_null :size_gib
    end
  end
end
