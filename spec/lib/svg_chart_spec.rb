# frozen_string_literal: true

require "open3"

RSpec.describe SvgChart do
  let(:t0) { 1700000000 }

  it "produces expected output for all scenarios" do
    golden_dir = "spec/lib/svg_chart-golden-files"
    output_dir = "spec/lib/svg_chart-spec-output-files"
    diff_file = "svg-chart-golden-files.diff"
    Dir.mkdir(output_dir) unless File.directory?(output_dir)

    scenarios = {
      "empty" => {points: []},
      "basic" => {points: [[t0, 10], [t0 + 3600, 20], [t0 + 7200, 15]]},
      "with-nonce" => {points: [[t0, 10], [t0 + 3600, 20]], nonce: "abc123"},
      "with-formatter" => {points: [[t0, 10], [t0 + 3600, 20]], label_formatter: ->(v) { "#{v.round}B" }},
      "single-point" => {points: [[t0, 5]]},
      "zero-values" => {points: [[t0, 0], [t0 + 3600, 0]]},
      "large-values" => {points: [[t0, 1_000_000], [t0 + 3600, 2_000_000]]},
      "identical-timestamps" => {points: [[t0, 10], [t0, 20]]},
      "many-points" => {points: Array.new(50) { |i| [t0 + i * 60, Math.sin(i / Math::PI) * 100 + 100] }},
    }

    scenarios.each do |name, opts|
      svg = described_class.render(opts[:points], nonce: opts[:nonce], label_formatter: opts[:label_formatter])
      File.write(File.join(output_dir, "#{name}.svg"), svg)
    end

    diff, = Open3.capture2e("diff", "-u", golden_dir, output_dir)

    if diff.empty?
      File.delete(diff_file) if File.file?(diff_file)
    else
      File.write(diff_file, diff)
    end

    expect(diff).to be_empty, "differences are in #{diff_file}"

    Dir["#{output_dir}/*"].each { File.delete(it) }
    Dir.rmdir(output_dir)
  end
end
