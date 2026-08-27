# frozen_string_literal: true

require_relative "../lib/kubernetes_sanitize_node_image"

RSpec.describe KubernetesSanitizeNodeImage do
  subject(:sanitizer) { described_class.new }

  describe "#run" do
    it "runs the sanitize script" do
      expect(sanitizer).to receive(:_run_command).with("bash", "-s", stdin: described_class::SCRIPT)

      sanitizer.run
    end
  end
end
