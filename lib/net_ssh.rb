# frozen_string_literal: true

require "net/ssh"
require "shellwords"

# :nocov:
module NetSsh
  def self.command(command, **)
    WarnUnsafe.convert(command, self, __callee__, **)
  end

  def self.combine(*commands, joiner: " ")
    # This will check that both command strings are already frozen before joining them.
    commands.map { WarnUnsafe.convert(it, self, __callee__) }.join(joiner).freeze
  end

  module WarnUnsafe
    def self.convert(command, klass, method, **kw)
      raise "invalid type passed to #{klass}##{method}: #{command.inspect}" unless command.is_a?(String)

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
        Kernel.warn "\npotentially unsafe string passed to #{klass}##{method}: #{command.inspect}", uplevel: 2
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
        def _exec!(_, status: nil)
        end

        def exec!(command, **kw)
          pass_kw = WarnUnsafe.extract_keywords(kw, %i[status])
          _exec!(WarnUnsafe.convert(command, self.class, __callee__, **kw), **pass_kw)
        end
      else
        def exec!(command, **kw)
          pass_kw = WarnUnsafe.extract_keywords(kw, %i[status])
          super(WarnUnsafe.convert(command, self.class, __callee__, **kw), **pass_kw)
        end
      end

      ::Net::SSH::Connection::Session.prepend self
    end

    module Sshable
      if Config.test?
        def _cmd(_, stdin: nil, log: true, timeout: :default)
        end

        # _skip_command_checking is a an extra keyword argument only for use in the
        # Sshable model specs, to test the actual implementation. All other specs
        # mock _cmd.
        def cmd(cmd, _skip_command_checking: false, **kw)
          return super(cmd, **kw) if _skip_command_checking
          pass_kw = WarnUnsafe.extract_keywords(kw, %i[stdin log timeout])
          _cmd(WarnUnsafe.convert(cmd, self.class, __callee__, **kw), **pass_kw)
        end
      else
        def cmd(cmd, **kw)
          pass_kw = WarnUnsafe.extract_keywords(kw, %i[stdin log timeout])
          super(WarnUnsafe.convert(cmd, self.class, __callee__, **kw), **pass_kw)
        end
      end
    end
  end
end
