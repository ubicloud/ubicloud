# frozen_string_literal: true

class SvgChart
  WIDTH = 600
  HEIGHT = 200
  PADDING_TOP = 10
  PADDING_RIGHT = 30
  PADDING_BOTTOM = 30
  PADDING_LEFT = 70
  CHART_WIDTH = WIDTH - PADDING_LEFT - PADDING_RIGHT
  CHART_HEIGHT = HEIGHT - PADDING_TOP - PADDING_BOTTOM
  GRID_LINES = 5
  TIME_LABELS = 5

  # points: array of [timestamp, value] pairs, sorted by timestamp
  # label_formatter: optional callable to format y-axis labels
  def self.render(points, label_formatter: nil, nonce: nil)
    new(points, label_formatter:, nonce:).render
  end

  def initialize(points, label_formatter: nil, nonce: nil)
    @points = points
    @label_formatter = label_formatter
    @nonce = nonce
  end

  def render
    return "<em>No data available</em>" if @points.empty?

    nonce_attr = @nonce ? " nonce=\"#{@nonce}\"" : ""
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{WIDTH}" height="#{HEIGHT}"#{nonce_attr} class="svg-chart">
        #{grid_lines}
        #{time_labels}
        <path d="#{area_path}" fill="rgba(70,130,180,0.15)"/>
        <path d="#{line_path}" fill="none" stroke="#369" stroke-width="1.5"/>
      </svg>
    SVG
  end

  private

  def min_t = @points.first[0]

  def max_t = @points.last[0]

  def span_t = @span_t ||= [max_t - min_t, 1].max

  def max_v = @max_v ||= [(@points.map { |p| p[1] }.max || 0) * 1.1, 1].max

  def scale_x(t)
    PADDING_LEFT + (t - min_t).to_f / span_t * CHART_WIDTH
  end

  def scale_y(v)
    PADDING_TOP + CHART_HEIGHT - v.to_f / max_v * CHART_HEIGHT
  end

  def line_path
    @points.each_with_index.map { |p, i|
      "#{(i == 0) ? "M" : "L"}#{scale_x(p[0]).round(1)},#{scale_y(p[1]).round(1)}"
    }.join
  end

  def area_path
    "#{line_path}L#{scale_x(@points.last[0]).round(1)},#{PADDING_TOP + CHART_HEIGHT}L#{scale_x(@points.first[0]).round(1)},#{PADDING_TOP + CHART_HEIGHT}Z"
  end

  def format_label(v)
    @label_formatter ? @label_formatter.call(v) : v.round(1)
  end

  def grid_lines
    Array.new(GRID_LINES) do |i|
      v = max_v / (GRID_LINES - 1) * i
      y = scale_y(v).round(1)
      label = format_label(v)
      %(<line x1="#{PADDING_LEFT}" y1="#{y}" x2="#{WIDTH - PADDING_RIGHT}" y2="#{y}" stroke="#eee"/>) +
        %(<text x="#{PADDING_LEFT - 4}" y="#{y + 3}" text-anchor="end" fill="#666">#{label}</text>)
    end.join("\n  ")
  end

  def time_labels
    Array.new(TIME_LABELS) do |i|
      t = min_t + span_t / (TIME_LABELS - 1).to_f * i
      x = scale_x(t).round(1)
      %(<text x="#{x}" y="#{HEIGHT - 4}" text-anchor="middle" fill="#666">#{Time.at(t).utc.strftime("%H:%M")}</text>)
    end.join("\n  ")
  end
end
