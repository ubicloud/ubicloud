# frozen_string_literal: true

Sequel.migration do
  first_month = Date.new(2027)
  months = Array.new(12) { |i| first_month.next_month(i) }
  tables = %i[audit_log account_authentication_audit_log admin_account_authentication_audit_log]

  up do
    tables.each do |table|
      months.each do |month|
        partition = :"#{table}_#{month.strftime("%Y_%m")}"
        create_table(partition) do
          like table, including: :all
        end

        alter_table(table) do
          attach_partition partition do
            from month
            to month.next_month
          end
        end
      end
    end
  end

  down do
    tables.each do |table|
      months.each do |month|
        partition = :"#{table}_#{month.strftime("%Y_%m")}"
        alter_table(table) do
          detach_partition partition
        end

        drop_table(partition)
      end
    end
  end
end
