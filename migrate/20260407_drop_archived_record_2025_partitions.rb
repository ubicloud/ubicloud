# frozen_string_literal: true

Sequel.migration do
  up do
    Array.new(4) { |i| Date.new(2025, 9, 1).next_month(i) }.each do |month|
      drop_table("archived_record_#{month.strftime("%Y_%m")}")
    end
  end

  down do
    Array.new(4) { |i| Date.new(2025, 9, 1).next_month(i) }.each do |month|
      create_table("archived_record_#{month.strftime("%Y_%m")}", partition_of: :archived_record) do
        from month
        to month.next_month
      end
    end
  end
end
