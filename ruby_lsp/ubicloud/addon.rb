# typed: false
# frozen_string_literal: true

require "ruby_lsp/addon"

module RubyLsp
  module Ubicloud
    # Minimal ruby-lsp add-on whose only job is to load the indexing enhancement below.
    class Addon < ::RubyLsp::Addon
      def activate(global_state, outgoing_queue) = nil

      def deactivate = nil

      def name = "Ubicloud"

      def version = "0.1.0"
    end

    # `label def <name>` (prog/base.rb) generates a hop_<name> method with a dynamic name
    # that ruby-lsp can't see. Register it so go-to-definition jumps to the labelled method.
    class ProgLabelEnhancement < RubyIndexer::Enhancement
      #: (Prism::CallNode node) -> void
      def on_call_node_enter(node)
        return unless node.name == :label && node.receiver.nil?

        definition = node.arguments&.arguments&.first
        return unless definition.is_a?(Prism::DefNode)

        name = definition.name
        @listener.add_method("hop_#{name}", definition.name_loc, [], comments: "Transitions the strand to the `#{name}` label.")
      end
    end
  end
end
