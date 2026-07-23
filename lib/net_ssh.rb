# frozen_string_literal: true

require "net/ssh"
require "shellwords"
require_relative "../rhizome/common/lib/command"

module NetSsh
  class MissingMock < StandardError
  end

  PotentialInsecurity = Command::PotentialInsecurity

  # Allow SSH calls from web process if specific ENV variable is set.
  WEB_SSH_DISABLED = ENV["PROCESS_TYPE"] == "web" && ENV["ALLOW_WEB_SSH"] != "true"

  def self.command(command, **)
    WarnUnsafe.convert(command, self, __callee__, **)
  end

  # :nocov:
  if Config.unfrozen_test?
    # :nocov:
    def self.prod_command(command, **)
      WarnUnsafe.convert(command, self, nil, **)
    end
  end

  def self.combine(*commands, joiner: " ")
    # This will check that both command strings are already frozen before joining them.
    commands.map { WarnUnsafe.convert(it, self, __callee__) }.join(joiner).freeze
  end

  module WarnUnsafe
    def self.convert(command, klass, method, **kw)
      Command.build(command, "#{klass}##{method}", __FILE__, Config.unfrozen_test? && method, **kw)
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

      if WEB_SSH_DISABLED
        ::Net::SSH.send(:remove_const, :Connection)
        ::Net::SSH.singleton_class.send(:undef_method, :start)
      # :nocov:
      else
        ::Net::SSH::Connection::Session.prepend self
      end
    end

    module Sshable
      # :nocov:
      if WEB_SSH_DISABLED
        def cmd(cmd, _skip_command_checking: false, **kw)
          raise "Sshable#cmd is not allowed from the web process"
        end
      # :nocov:
      elsif Config.test?
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
