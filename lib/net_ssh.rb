# frozen_string_literal: true

require "net/ssh"
require "shellwords"

module NetSsh
  class MissingMock < StandardError
  end

  class PotentialInsecurity < StandardError
  end

  def self.command(command, **)
    WarnUnsafe.convert(command, self, __callee__, **)
  end

  def self.combine(*commands, joiner: " ")
    # This will check that both command strings are already frozen before joining them.
    commands.map { WarnUnsafe.convert(it, self, __callee__) }.join(joiner).freeze
  end

  module WarnUnsafe
    def self.convert(command, klass, method, **kw)
      raise TypeError, "invalid type passed to #{klass}##{method}: #{command.inspect}" unless command.is_a?(String)

      if command.frozen?
        unless kw.empty?
          command = Sequel.lit(command, kw.to_h do |k, v|
            v = if k.start_with?("shelljoin_")
              v.shelljoin
            else
              v.to_s.shellescape
            end
            [k, Sequel.lit(v)]
          end)
          command = DB.literal(command).freeze
        end
      else
        raise PotentialInsecurity, "Interpolated string passed to #{klass}##{method} at #{caller(2, 1).first}\nReplace interpolation with :placeholders and provide values for placeholders in keyword arguments."
      end

      command
    end

    def self.extract_keywords(kw, syms)
      pass_kw = {}
      syms.each do |sym|
        pass_kw[sym] = kw.delete(sym) if kw.include?(sym)
      end
      pass_kw
    end

    module SshSession
      if Config.test?
        def _exec!(command, status: nil)
          raise MissingMock, "Net::SSH::Connection::Session#_exec! not mocked. You must add a spec that checks for the expected command. Command: #{command.inspect}"
        end

        def exec!(command, **kw)
          pass_kw = WarnUnsafe.extract_keywords(kw, %i[status])
          _exec!(WarnUnsafe.convert(command, self.class, __callee__, **kw), **pass_kw)
        end
      # :nocov:
      else
        def exec!(command, **kw)
          pass_kw = WarnUnsafe.extract_keywords(kw, %i[status])
          super(WarnUnsafe.convert(command, self.class, __callee__, **kw), **pass_kw)
        end
      end
      # :nocov:

      ::Net::SSH::Connection::Session.prepend self
    end

    module Sshable
      if Config.test?
        def _cmd(command, stdin: nil, log: true, timeout: :default)
          raise MissingMock, "Sshable#_cmd not mocked. You must add a spec that checks for the expected command. Command: #{command.inspect}"
        end

        # _skip_command_checking is a an extra keyword argument only for use in the
        # Sshable model specs, to test the actual implementation. All other specs
        # mock _cmd.
        def cmd(cmd, _skip_command_checking: false, **kw)
          return super(cmd, **kw) if _skip_command_checking
          pass_kw = WarnUnsafe.extract_keywords(kw, %i[stdin log timeout])
          _cmd(WarnUnsafe.convert(cmd, self.class, __callee__, **kw), **pass_kw)
        end
      # :nocov:
      else
        def cmd(cmd, **kw)
          pass_kw = WarnUnsafe.extract_keywords(kw, %i[stdin log timeout])
          super(WarnUnsafe.convert(cmd, self.class, __callee__, **kw), **pass_kw)
        end
      end
      # :nocov:
    end
  end
end
