# frozen_string_literal: true

require "shellwords"

# Safely build a shell command string from a template containing :placeholder
# tokens and keyword arguments for the placeholder values, performing shell
# escaping for each value. Used by both rhizome and clover.
module Command
  extend self

  class PotentialInsecurity < StandardError
  end

  # command: a template command string with zero or more :placeholder tokens
  #   matching arguments in kw.  A keyword argument whose name starts with
  #   "shelljoin_" is expected to hold an Array, and is joined into multiple
  #   shell-escaped words instead of one.
  # name: label used in error messages to identify the caller (e.g. "cmd" or
  #   "Sshable#cmd").
  # wrapper_file: __FILE__ of the method calling into this one, so error
  #   messages can point at the code that actually called it, by skipping
  #   both this file's backtrace frames and the wrapper's.
  # strict: whether to use the (slower) quote-tracking parser that also
  #   rejects placeholders inside quotes. When false, a plain regex
  #   substitution is used instead, which is only safe when the template has
  #   already been verified (e.g. by tests that use the strict parser) to
  #   never place a placeholder inside quotes.
  def build(command, name, wrapper_file, strict, **kw)
    raise TypeError, "invalid type passed to #{name}: #{command.inspect}" unless command.is_a?(String)

    if command.frozen?
      return command if kw.empty?

      if strict
        result = +""
        mode = :unquoted
        base_re = Regexp.union(kw.keys.map(&:to_s))
        unquoted_re, single_re, double_re = nil
        until command.empty?
          re = case mode
          when :unquoted
            unquoted_re ||= /(\\.|['"]|#.*$)|:(#{base_re})\b/
          when :single
            single_re ||= /(')|:(#{base_re})\b/
          else # :double
            double_re ||= /(\\.|")|:(#{base_re})\b/
          end

          pre, _, command = command.partition(re)
          ch = $1
          q = $2

          if ch
            case mode
            when :unquoted
              case ch
              when "'"
                mode = :single
              when '"'
                mode = :double
              end
            when :single
              mode = :unquoted
            else # :double
              mode = :unquoted if ch == '"'
            end
            result << pre << ch
          elsif mode != :unquoted
            if q && !q.empty?
              raise PotentialInsecurity, "Placeholder '#{q}' inside #{mode} quote in command#{at(wrapper_file)}\nFix command to move the placeholder outside quotes, because shell escaping does not work correctly inside quotes."
            end
          else
            result << pre
            if q && !q.empty?
              v = kw[q.to_sym]
              result << if q.start_with?("shelljoin_")
                v.shelljoin
              else
                v.to_s.shellescape
              end
            end
          end
        end

        unless mode == :unquoted
          raise PotentialInsecurity, "Unterminated #{mode} quote in command#{at(wrapper_file)}\nFix command syntax."
        end
        # :nocov:
      else
        # This branch is covered by the clover specs, but not by the rhizome specs.
        # It's marked nocov so the rhizome specs don't fail due to coverage reasons.
        re = /:(#{Regexp.union(kw.keys.map(&:to_s))})\b/
        result = +""
        until command.empty?
          pre, _, command = command.partition(re)
          q = $1
          result << pre
          if q && !q.empty?
            v = kw[q.to_sym]
            result << if q.start_with?("shelljoin_")
              v.shelljoin
            else
              v.to_s.shellescape
            end
          end
        end
      end
      # :nocov:

      command = result.freeze
    else
      raise PotentialInsecurity, "Interpolated string passed to #{name}#{at(wrapper_file)}\nReplace interpolation with :placeholders and provide values for placeholders in keyword arguments."
    end

    command
  end

  if Thread.respond_to?(:each_caller_location)
    # Returns string for location of method call that is causing a PotentialInsecurity
    def at(wrapper_file)
      Thread.each_caller_location do |loc|
        return " at #{loc}" unless loc.path == __FILE__ || loc.path == wrapper_file
      end

      # :nocov:
      ""
    end
  else
    def at(wrapper_file)
      ""
    end
  end
  # :nocov:
end
