require "psych"


class OpenapiChores < Psych::Handler
  def initialize(*, **)
    @path = []
    @emitter = Psych::Emitter.new(*, **)
    @state = :top
  end

  def event_location(start_line, start_column, end_line, end_column)
    @start_line = start_line
    @start_column = start_column
    @end_line = end_line
    @end_column = end_column
  end

  def start_stream(encoding)
    @emitter.start_stream(encoding)
  end

  def end_stream
    @emitter.end_stream
  end

  def start_document(version, tag_directives, implicit)
    p @state = :start_document
    @emitter.start_document(version, tag_directives, implicit)
  end

  def end_document(implicit)
    @state = :end_document
    @emitter.end_document(implicit)
  end

  def start_mapping(anchor, tag, implicit, style)
    @state = :start_map
    @emitter.start_mapping(anchor, tag, implicit, style)
  end

  def end_mapping
    @state = :end_map
    @path.pop
    @emitter.end_mapping
  end

  def start_sequence(anchor, tag, implicit, style)
    @state = :start_sequence
    @emitter.start_sequence(anchor, tag, implicit, style)
  end

  def end_sequence
    @state = :end_sequence
    @emitter.end_sequence
  end

  def scalar(value, anchor, tag, plain, quoted, style)
    case @state
    when :start_map
      p value
      @path << value
    end
    @state = :scalar

    @emitter.scalar(value, anchor, tag, plain, quoted, style)
  end

  def alias(anchor)
    @state = :alias
    @emitter.alias(anchor)
  end
end
