# frozen_string_literal: true

class Clover < Roda
  def paginated_result(dataset, serializer)
    opts = typecast_params.convert!(symbolize: true) do |tp|
      tp.str(%w[start_after order_column])
      tp.pos_int("page_size")
    end

    result = dataset.paginated_result(**opts)

    {
      items: serializer.serialize(result[:records]),
      count: result[:count]
    }
  end
end
