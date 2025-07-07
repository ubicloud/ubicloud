# frozen_string_literal: true

class Clover < Roda
  def paginated_result(dataset, serializer)
    opts = typecast_params.convert!(symbolize: true) do |tp|
      tp.str(%w[start_after order_column])
      tp.pos_int("page_size")
    end
    opts[:serializer] = serializer

    dataset.paginated_result(**opts)
  end
end
