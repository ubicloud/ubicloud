# frozen_string_literal: true

Sequel.migration do
  change do
    # Rest of 2026

    first_month = Date.new(2026, 7)
    Array.new(6) { |i| first_month.next_month(i) }.each do |month|
      create_table("audit_log_#{month.strftime("%Y_%m")}", partition_of: :audit_log) do
        from month
        to month.next_month
      end
    end

    # When creating 2027 partitions, include partitions for:
    # * account_authentication_audit_log
    # * admin_account_authentication_audit_log

    first_month = Date.new(2026, 11)
    Array.new(2) { |i| first_month.next_month(i) }.each do |month|
      create_table("archived_record_#{month.strftime("%Y_%m")}", partition_of: :archived_record) do
        from month
        to month.next_month
      end
    end
  end
end
