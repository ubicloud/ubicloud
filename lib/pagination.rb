# frozen_string_literal: true

module Pagination
  def paginated_result(start_after: nil, page_size: nil, order_column: nil, serializer: nil, serializer_opts: nil)
    model = @opts[:model]
    page_size ||= 1000
    order_column_sym = (order_column || "id").to_sym

    begin
      page_size = Integer(page_size).clamp(1, 1000)
    rescue ArgumentError
      fail Validation::ValidationFailed.new(page_size: "#{page_size} is not an integer")
    end

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

    query = order(order_column_sym).limit(page_size)
    query = query.where(Sequel[model.table_name][order_column_sym] > start_after) if start_after
    items = query.all
    items = serializer.serialize(items, **serializer_opts) if serializer

    {items:, count:}
  end
end
