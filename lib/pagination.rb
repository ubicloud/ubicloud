# frozen_string_literal: true

module Pagination
  module Dataset
    def paginated_result(cursor, page_size, order_column)
      model = @opts[:model]
      page_size = (page_size&.to_i || 10).clamp(1, 100)
      order_column_sym = (order_column || "id").to_sym

      fail Validation::ValidationFailed.new({cursor: "No resource exist with the given id #{cursor}"}) if cursor && model.from_ubid(cursor).nil?
      fail Validation::ValidationFailed.new({order_column: "Given order column does not exist for the resource"}) unless model.columns.include?(order_column_sym)

      if cursor
        cursor_order_column_value = model.from_ubid(cursor).send(order_column_sym)
        page_records = where(Sequel.qualify(model.table_name, order_column_sym) >= cursor_order_column_value).order(order_column_sym).limit(page_size + 1).all
      else
        page_records = order(order_column_sym).limit(page_size + 1).all
      end

      if page_records.length > page_size
        next_cursor = page_records.last.ubid
        page_records.pop
      end

      {records: page_records, next_cursor: next_cursor, count: count}
    end
  end
end
