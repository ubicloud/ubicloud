# frozen_string_literal: true

module Pagination
  def paginated_result(start_after: nil, page_size: nil, order_column: nil)
    model = @opts[:model]
    page_size = (page_size&.to_i || 10).clamp(1, 100)
    order_column_sym = (order_column || "id").to_sym

    if start_after && order_column_sym == :id
      begin
        start_after = UBID.parse(start_after).to_uuid
      rescue
        fail Validation::ValidationFailed.new(start_after: "#{start_after} is not a valid ID")
      end
    end

    # For now, ordering by ubid is supported for all resource types, as ubid is always unique.
    # Ordering by name is supported for location-based resources having a name column.
    # Since the project is the only global resource for now, explicit check is added.
    supported_order_columns = [:id]
    if model.table_name != :project && model.columns.include?(:name)
      supported_order_columns << :name
    end

    unless supported_order_columns.include?(order_column_sym)
      fail Validation::ValidationFailed.new(order_column: "Supported ordering columns: #{supported_order_columns.join(", ")}")
    end

    # Get page_size + 1 records to return the last element as the next_value
    # by popping it from the records
    query = model.order(order_column_sym).limit(page_size + 1)
    query = query.where(Sequel[model.table_name][order_column_sym] > start_after) if start_after
    page_records = query.all
    if page_records.length > page_size
      next_cursor = page_records.pop.ubid
    end

    {records: page_records, next_cursor: next_cursor, count: count}
  end
end
