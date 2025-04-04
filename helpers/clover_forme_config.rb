# frozen_string_literal: true

require "forme"

Forme.register_transformer(:wrapper, :ubicloud) do |tag, input|
  tag = case input.type
  when :radioset
    input.tag("div", {"class" => "space-y-2 #{input.opts[:provides]&.split&.map { "provides-#{_1}" }&.join}"}, tag)
  when :radio
    return tag
  else
    input.tag("div", {"class" => "space-y-2 text-gray-900"}, tag)
  end

  input.tag("div", {"class" => input.opts.fetch(:main_wrapper_class, "col-span-full")}, tag)
end

Forme.register_transformer(:labeler, :ubicloud) do |tag, input|
  label = input.opts[:label]
  id = input.opts[:id] || input.opts[:key]

  case input.type
  when :radioset
    [
      input.tag("label", {"class" => "text-sm font-medium leading-6 text-gray-900"}, label),
      input.tag("fieldset", {"class" => "radio-small-cards"}, [
        input.tag("legend", {"class" => "sr-only"}, label),
        input.tag("div", {"class" => "grid gap-3 grid-cols-1 sm:grid-cols-2 md:grid-cols-3 xl:grid-cols-4"}, tag)
      ])
    ]
  when :radio
    input.tag("label", {}, [
      tag,
      input.tag("span", {"class" => "radio-small-card justify-center p-3 text-sm font-semibold"}, label)
    ])
  else
    [
      input.tag("label", {"for" => id, "class" => "block text-sm font-medium leading-6"}, label),
      input.tag("div", {"class" => "flex gap-x-2"}, tag)
    ]
  end
end

Forme.register_transformer(:formatter, :ubicloud, Class.new(Forme::Formatter) do
  def default_classes_for_type(type)
    if @input.opts[:error]
      case type
      when :text
        "block w-full rounded-md border-0 py-1.5 pl-3 pr-10 shadow-sm ring-1 ring-inset focus:ring-2 focus:ring-inset sm:text-sm sm:leading-6 text-red-900 ring-red-300 placeholder:text-red-300 focus:ring-red-500"
      when :radio
        "peer sr-only"
      when :select
        "block w-full rounded-md border-0 py-1.5 pl-3 pr-10 shadow-sm ring-1 ring-inset focus:ring-2 focus:ring-inset sm:text-sm sm:leading-6 text-red-900 ring-red-300 placeholder:text-red-300 focus:ring-red-500"
      end
    else
      case type
      when :text
        "block w-full rounded-md border-0 py-1.5 pl-3 pr-10 shadow-sm ring-1 ring-inset focus:ring-2 focus:ring-inset sm:text-sm sm:leading-6 text-gray-900 ring-gray-300 placeholder:text-gray-400 focus:ring-orange-600"
      when :radio
        "peer sr-only"
      when :select
        "block w-full rounded-md border-0 py-1.5 pl-3 pr-10 shadow-sm ring-1 ring-inset focus:ring-2 focus:ring-inset sm:text-sm sm:leading-6 text-gray-900 ring-gray-300 placeholder:text-gray-400 focus:ring-orange-600"
      end
    end
  end

  def normalize_options
    super
    if @input.type == :radioset
      @opts[:labeler] ||= :ubicloud
      # Select the first option by default if there is no default set
      @opts[:selected] = @opts.dig(:options, 0, 1) unless @opts[:selected]
    end

    if !@opts.has_key?(:class) && (classes = default_classes_for_type(@input.type))
      Forme.attr_classes(@attr, classes)
    end
  end
end)

Forme.register_transformer(:error_handler, :ubicloud) do |tag, input|
  [
    tag,
    input.tag("p", {"class" => "text-sm text-red-600 leading-6", "id" => "#{input.opts[:key]}-error"}, input.opts[:error])
  ]
end

Forme.register_config(:ubicloud, wrapper: :ubicloud, labeler: :ubicloud, formatter: :ubicloud, error_handler: :ubicloud)
Forme.default_config = :ubicloud
