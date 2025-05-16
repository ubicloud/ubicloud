# frozen_string_literal: true

Sequel.migration do
  change do
    Array.new(4) { |i| Date.new(2024, 12, 1).next_month(i) }.each do |month|
      drop_table("archived_record_#{month.strftime("%Y_%m")}")
    end

    Array.new(4) { |i| Date.new(2026, 2, 1).next_month(i) }.each do |month|
      create_table("archived_record_#{month.strftime("%Y_%m")}", partition_of: :archived_record) do
        from month
        to month.next_month
      end
    end
  end
end
