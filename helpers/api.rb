# frozen_string_literal: true

class Clover < Roda
  def paginated_result(dataset, serializer, **serializer_opts)
    opts = typecast_params.convert!(symbolize: true) do |tp|
      tp.str(%w[start_after order_column])
      tp.pos_int("page_size")
    end
    opts[:serializer] = serializer
    opts[:serializer_opts] = serializer_opts

    dataset.paginated_result(**opts)
  end
end
