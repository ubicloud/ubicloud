# frozen_string_literal: true

require "shellwords"

# Safely build a shell command string from a template containing :placeholder
# tokens, substituting each with a keyword argument, shell-escaped. Shared
# between rhizome/common/lib/util.rb's `cmd` and lib/net_ssh.rb's
# NetSsh::WarnUnsafe.convert, which otherwise duplicated the same algorithm.
module Command
  class PotentialInsecurity < StandardError
  end

  # command: a frozen template string (unless kw is empty, in which case any
  #   string works) with zero or more :placeholder tokens matching keys in
  #   kw. A keyword whose name starts with "shelljoin_" is expected to hold
  #   an Array, joined into multiple shell-escaped words instead of one.
  #   Placeholders are not allowed inside quotes, since shell-escaping a
  #   value for unquoted context and then wrapping it in quotes anyway
  #   produces incorrect (and unsafe) results.
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
  #
  # name, wrapper_file, and strict are positional (not keyword) arguments so
  # that a placeholder legitimately named :name, :wrapper_file, or :strict in
  # kw can never collide with (and silently get absorbed out of kw by) them.
  def self.build(command, name, wrapper_file, strict, **kw)
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
      else
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

      command = result.freeze
    else
      raise PotentialInsecurity, "Interpolated string passed to #{name}#{at(wrapper_file)}\nReplace interpolation with :placeholders and provide values for placeholders in keyword arguments."
    end

    command
  end

  # Returns " at file:line:in `method'" for the first backtrace location
  # outside this file and wrapper_file, or "" if that can't be determined
  # (Thread.each_caller_location was added in Ruby 3.2).
  def self.at(wrapper_file)
    return "" unless Thread.respond_to?(:each_caller_location)

    Thread.each_caller_location do |loc|
      return " at #{loc}" unless loc.path == __FILE__ || loc.path == wrapper_file
    end

    ""
  end
end
