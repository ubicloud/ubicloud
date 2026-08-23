# frozen_string_literal: true

Sequel.migration do
  revert do
    Array.new(3) { |i| Date.new(2026, 5, 1).next_month(i) }.each do |month|
      create_table("archived_record_#{month.strftime("%Y_%m")}", partition_of: :archived_record) do
        from month
        to month.next_month
      end
    end
  end
end
