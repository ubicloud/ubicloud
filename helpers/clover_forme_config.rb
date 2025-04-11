# frozen_string_literal: true

require "forme"

Forme.register_transformer(:wrapper, :ubicloud) do |tag, input|
  tag = case input.type
  when :radioset
    input.tag("div", {"class" => "space-y-2 dependency-radioset #{"provider" if input.opts[:provides]} #{input.opts[:provides]&.split&.map { "provides-#{_1}" }&.join}", "dependencies" => input.opts[:dependencies]}, tag)
  when :radio
    return tag
  when :checkboxset
    main_wrapper_class = "space-y-2 text-gray-900"
    input.tag("fieldset") do
      input.tag("div", {"class" => "space-y-5"}, tag)
    end
  else
    input.tag("div", {"class" => "space-y-2 text-gray-900"}, tag)
  end

  main_wrapper_class ||= input.opts.fetch(:main_wrapper_class, "col-span-full")
  input.tag("div", {"class" => main_wrapper_class}, tag)
end

Forme.register_transformer(:labeler, :ubicloud, Class.new(Forme::Labeler::Explicit) do
  def call(tag, input)
    label = input.opts[:label]
    id = id_for_input(input)

    case input.type
    when :radioset
      div_classes = case input.opts[:display_type]
      when :family, :size, :storage_size, :ha_type
        "grid gap-3 grid-cols-1 md:grid-cols-2 xl:grid-cols-3"
      else
        "grid gap-3 grid-cols-1 sm:grid-cols-2 md:grid-cols-3 xl:grid-cols-4"
      end

      [
        input.tag("label", {"class" => "text-sm font-medium leading-6 text-gray-900"}, label),
        input.tag("fieldset", {"class" => "radio-small-cards"}, [
          input.tag("legend", {"class" => "sr-only"}, label),
          input.tag("div", {"class" => div_classes}, tag)
        ])
      ]
    when :radio
      label_attr = input.opts[:label_attr]

      if (parent = input.opts[:parent]) && parent.opts[:display_type]
        display_type = parent.opts[:display_type]
      end

      label_tag = case display_type
      when :family
        family = Option::VmFamilyMap[label]
        input.tag("span", {"class" => "radio-small-card justify-between p-4"}) do
          input.tag("span", {"class" => "flex flex-col"}) do
            [
              input.tag("span", {"class" => "text-md font-semibold"}, family.display_name),
              input.tag("span", {"class" => "text-sm opacity-80"}) do
                input.tag("span", {"class" => "block sm:inline"}, family.ui_descriptor)
              end
            ]
          end
        end
      when :size, :storage_size, :ha_type
        name, cpu_mem, per_month, per_hour = input.opts[:display_data]
        input.tag("span", {"class" => "radio-small-card justify-between p-4"}) do
          [
            input.tag("span", {"class" => "flex flex-col"}) do
              [
                input.tag("span", {"class" => "text-md font-semibold"}, name),
                if cpu_mem
                  input.tag("span", {"class" => "text-sm opacity-80"}) do
                    input.tag("span", {"class" => "block sm:inline"}, cpu_mem)
                  end
                end
              ]
            end,
            input.tag("span", {"class" => "mt-2 flex text-sm sm:ml-4 sm:mt-0 sm:flex-col sm:text-right"}) do
              [
                input.tag("span", {"class" => "font-medium"}, per_month),
                input.tag("span", {"class" => "ml-1 opacity-50 sm:ml-0"}, per_hour)
              ]
            end
          ]
        end
      else
        input.tag("span", {"class" => "radio-small-card justify-center p-3 text-sm font-semibold"}, label)
      end

      input.tag("label", label_attr, [tag, label_tag])
    when :checkbox
      input.tag("div", {"class" => "relative flex items-start"}) do
        [
          input.tag("div", {"class" => "flex h-6 items-center"}, tag),
          input.tag("div", {"class" => "ml-3 text-sm leading-6"}) do
            input.tag("label", {"for" => id, "class" => "font-medium text-gray-900"}, label)
          end
        ]
      end
    else
      [
        input.tag("label", {"for" => id, "class" => "block text-sm font-medium leading-6"}, label),
        input.tag("div", {"class" => "flex gap-x-2"}, tag)
      ]
    end
  end
end.new)

Forme.register_transformer(:formatter, :ubicloud, Class.new(Forme::Formatter) do
  def default_classes_for_type(type)
    if @input.opts[:error]
      case type
      when :text
        "block w-full rounded-md border-0 py-1.5 pl-3 pr-10 shadow-sm ring-1 ring-inset focus:ring-2 focus:ring-inset sm:text-sm sm:leading-6 text-red-900 ring-red-300 placeholder:text-red-300 focus:ring-red-500"
      when :radio
        "peer sr-only"
      when :checkbox
        "h-4 w-4 rounded border-gray-300 text-orange-600 focus:ring-orange-600"
      when :select
        "block w-full rounded-md border-0 py-1.5 pl-3 pr-10 shadow-sm ring-1 ring-inset focus:ring-2 focus:ring-inset sm:text-sm sm:leading-6 text-red-900 ring-red-300 placeholder:text-red-300 focus:ring-red-500"
      end
    else
      case type
      when :text
        "block w-full rounded-md border-0 py-1.5 pl-3 pr-10 shadow-sm ring-1 ring-inset focus:ring-2 focus:ring-inset sm:text-sm sm:leading-6 text-gray-900 ring-gray-300 placeholder:text-gray-400 focus:ring-orange-600"
      when :radio
        "peer sr-only"
      when :checkbox
        "h-4 w-4 rounded border-gray-300 text-orange-600 focus:ring-orange-600"
      when :select
        "block w-full rounded-md border-0 py-1.5 pl-3 pr-10 shadow-sm ring-1 ring-inset focus:ring-2 focus:ring-inset sm:text-sm sm:leading-6 text-gray-900 ring-gray-300 placeholder:text-gray-400 focus:ring-orange-600"
      end
    end
  end

  def normalize_options
    super

    if @input.type == :radioset
      @opts[:required] = true

      key = @opts[:key]

      if (validation_error = @form.opts[:validation_error]) && (error = validation_error.details[key])
        opts[:error] = error
      end

      key = key.to_s

      if (input_opts = @form.opts[:input_options]&.form_options(key))
        @opts.merge!(input_opts)
      end

      if @opts[:obj].nil? && (request = @form.opts[:request])
        @opts[:selected] ||= request.params[key]
      end

      @opts[:labeler] ||= :ubicloud
      unless @opts[:value]
        @opts[:selected] ||= begin
          # Select the first option by default if there is no default set
          value = @opts[:options][0]
          value = value[1] if value.is_a?(Array)
          value = value[:value] if value.is_a?(Hash)
          value
        end
      end
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
