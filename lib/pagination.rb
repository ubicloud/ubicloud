# frozen_string_literal: true

module Pagination
  def paginated_result(cursor: nil, page_size: nil, order_column: nil)
    model = @opts[:model]
    page_size = (page_size&.to_i || 10).clamp(1, 100)
    order_column_sym = (order_column || "id").to_sym

    fail Validation::ValidationFailed.new({cursor: "No resource exist with the given id #{cursor}"}) if cursor && !model.from_ubid(cursor)
    fail Validation::ValidationFailed.new({order_column: "Given order column does not exist for the resource"}) unless model.columns.include?(order_column_sym)

    # Get page_size + 1 records to return the last element as the next_cursor
    # by popping it from the records
    if cursor
      cursor_order_column_value = model.from_ubid(cursor).send(order_column_sym)
      page_records = where(Sequel[model.table_name][order_column_sym] >= cursor_order_column_value).order(order_column_sym).limit(page_size + 1).all
    else
      page_records = order(order_column_sym).limit(page_size + 1).all
    end

    if page_records.length > page_size
      next_cursor = page_records.pop.ubid
    end

    {records: page_records, next_cursor: next_cursor, count: count}
  end
end
