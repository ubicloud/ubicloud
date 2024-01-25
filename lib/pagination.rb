# frozen_string_literal: true

module Pagination
  module Dataset
    # TODO: Should we try chainable pagination like sequel's offset based pagination
    def paginated_result(cursor, page_size, order_column)
      model = @opts[:model]
      page_size ||= 10

      if cursor
        cursor_order_column = model.from_ubid(cursor).send(order_column)
        page_records = where(Sequel.qualify(model.table_name, order_column.to_sym) >= cursor_order_column).limit(page_size.to_i + 1).all
      else
        page_records = limit(page_size.to_i + 1).all
      end

      if page_records.length > page_size.to_i
        next_cursor = page_records.last&.ubid
        page_records.pop
      end

      {records: page_records, next_cursor: next_cursor, count: count}
    end
  end
end
