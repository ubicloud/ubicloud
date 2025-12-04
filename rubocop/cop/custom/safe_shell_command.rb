# frozen_string_literal: true

# rubocop/cop/custom/safe_shell_command.rb
require "rubocop"
require "shellwords"

module RuboCop
  module Cop
    module Custom
      class SafeShellCommand < RuboCop::Cop::Base
        extend AutoCorrector

        # Used with format(), so %%W escapes to %W
        MSG_UNSAFE_INTERPOLATION =
          "Unsafe interpolation. Converting to `%%W[]` will safely escape arguments, " \
          "but this disables shell features in: %s."

        # Used directly, so %W is literal
        MSG_AVOID_INTERPOLATION = "Avoid interpolation in shell commands. Use `cmd(%W[...])` instead."

        MSG_MANUAL_INTERVENTION =
          "Avoid interpolation in shell commands. This structure (heredoc or mid-word concatenation) " \
          "cannot be safely autocorrected to `%W[]`. Please refactor manually."

        def_node_matcher :cmd_call?, "(send !const {:cmd :exec!} $...)"

        def_node_matcher :wrapped_shell_escape?, <<~PATTERN
          (begin
            {
              (send $_ :shellescape)
              (send (const {nil? cbase} :Shellwords) :escape $_)
            }
          )
        PATTERN

        def on_send(node)
          return unless (args = cmd_call?(node))
          return if args.empty?

          first_arg = args.first
          return unless first_arg.dstr_type?

          if requires_manual_intervention?(first_arg)
            add_offense(node, message: MSG_MANUAL_INTERVENTION)
            return
          end

          check_interpolated_string(node, first_arg)
        end

        private

        def requires_manual_intervention?(dstr_node)
          return true if dstr_node.heredoc?
          check_for_mid_word_split(dstr_node)
        end

        def check_for_mid_word_split(dstr_node)
          children = dstr_node.children
          return false if children.size < 2

          children.each_cons(2) do |curr, next_child|
            line_break = next_child.loc.line > curr.loc.last_line
            next unless line_break

            # If we have a line break, we need whitespace at the seam.
            return true unless ends_with_space?(curr) || starts_with_space?(next_child)
          end

          false
        end

        # Recursively check the last string segment for trailing space
        def ends_with_space?(node)
          case node.type
          when :str
            node.value.match?(/\s$/)
          when :dstr
            last_child = node.children.last
            # FIX: Expanded if/else ensures branch coverage ignores the nocov path
            if last_child
              ends_with_space?(last_child)
            else
              # :nocov:
              raise "BUG: dstr node has no children in ends_with_space?. AST: #{node.inspect}"
              # :nocov:
            end
          else
            # Interpolation (begin) or other nodes are assumed "not space"
            false
          end
        end

        # Recursively check the first string segment for leading space
        def starts_with_space?(node)
          case node.type
          when :str
            node.value.match?(/^\s/)
          when :dstr
            first_child = node.children.first
            # FIX: Expanded if/else ensures branch coverage ignores the nocov path
            if first_child
              starts_with_space?(first_child)
            else
              # :nocov:
              raise "BUG: dstr node has no children in starts_with_space?. AST: #{node.inspect}"
              # :nocov:
            end
          else
            # Interpolation (begin) or other nodes are assumed "not space"
            false
          end
        end

        def check_interpolated_string(node, dstr_node)
          unsafe_words = find_unsafe_words_in_dstr(dstr_node)

          if unsafe_words.any?
            message = format(MSG_UNSAFE_INTERPOLATION, unsafe_words.inspect)
            add_offense(node, message: message)
          else
            add_offense(node, message: MSG_AVOID_INTERPOLATION) do |corrector|
              autocorrect_to_percent_w(corrector, dstr_node)
            end
          end
        end

        def find_unsafe_words_in_dstr(dstr_node) =
          dstr_node.children
            .select(&:str_type?)
            .flat_map { |child| find_unsafe_words(child.value) }

        def find_unsafe_words(text) =
          text.split(/\s+/)
            .reject(&:empty?)
            .reject { |word| Shellwords.escape(word) == word }

        def autocorrect_to_percent_w(corrector, dstr_node)
          parts = collect_parts(dstr_node)
          corrector.replace(dstr_node, "%W[#{parts.join}]")
        end

        def collect_parts(dstr_node)
          parts = []
          children = dstr_node.children

          children.each_with_index do |child, index|
            parts << process_child(child)

            # Insert newline only if there was a line break in source
            next_child = children[index + 1]
            if next_child && next_child.loc.line > child.loc.last_line
              parts << "\n"
            end
          end
          parts
        end

        def process_child(child)
          case child.type
          when :str
            child.value.gsub(/([\\\[\]#])/) { |m| "\\#{m}" }
          when :begin
            if (inner = wrapped_shell_escape?(child))
              "\#{#{inner.source}}"
            else
              child.source
            end
          when :dstr
            # Flatten nested dstr nodes (common in line continuations)
            collect_parts(child).join
          else
            # :nocov:
            raise "BUG: unexpected dstr child type: #{child.type.inspect}"
            # :nocov:
          end
        end
      end
    end
  end
end
