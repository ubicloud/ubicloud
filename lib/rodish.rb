# frozen_string_literal: true

require "optparse"

module Rodish
  def self.processor(&block)
    Processor.new(DSL.command([].freeze, [].freeze, &block))
  end

  class CommandExit < StandardError
    def failure?
      false
    end
  end

  class CommandFailure < CommandExit
    def failure?
      true
    end
  end

  class OptionParser < ::OptionParser
    attr_accessor :rodish_command

    # Don't add officious, which includes options that call exit
    def add_officious
    end

    def to_s
      string = super

      if @rodish_command && !@rodish_command.subcommands.empty?
        string += "\nSubcommands: #{@rodish_command.subcommands.keys.sort.join(" ")}\n"
      end

      string
    end

    def halt(string)
      raise CommandExit, string
    end
  end

  option_parser = DEFAULT_OPTION_PARSER = OptionParser.new
  option_parser.set_banner("")
  option_parser.freeze

  class DSL
    def self.command(command_path, befores, &block)
      command = Command.new(command_path, befores)
      new(command).instance_exec(&block)
      command
    end

    def initialize(command)
      @command = command
    end

    def options(banner, key: nil, &block)
      option_parser = OptionParser.new
      option_parser.set_banner("Usage: #{banner}")
      option_parser.separator ""
      option_parser.separator "Options:"
      option_parser.instance_exec(&block)
      option_parser.rodish_command = @command
      @command.option_key = key
      @command.option_parser = option_parser
    end

    def before(&block)
      @command.before = block
    end

    def args(args)
      @command.num_args = args
    end

    def autoload_subcommand_dir(base)
      Dir.glob("*.rb", base:).each do |filename|
        @command.subcommands[filename.chomp(".rb")] = File.expand_path(File.join(base, filename))
      end
    end

    def on(command_name, &block)
      command_path = @command.command_path + [command_name]
      @command.subcommands[command_name] = DSL.command(command_path.freeze, @command.befores, &block)
    end

    def run(&block)
      @command.run_block = block
    end

    def is(command_name, args: 0, &block)
      on(command_name) do
        args args
        run(&block)
      end
    end
  end

  class Command
    attr_reader :subcommands

    attr_accessor :run_block
    attr_accessor :command_path
    attr_accessor :option_parser
    attr_accessor :option_key
    attr_accessor :before
    attr_accessor :num_args

    def initialize(command_path, befores)
      # Development assertions:
      # raise "command path not frozen" unless command_path.frozen?
      # raise "befores not frozen" unless befores.frozen?
      @command_path = command_path
      @command_name = command_path.join(" ").freeze
      @befores = befores
      @subcommands = {}
      @num_args = 0
    end

    def freeze
      @subcommands.each_value(&:freeze)
      if @before
        @befores += [@before]
        @befores.freeze
        @before = nil
      end
      @subcommands.freeze
      @option_parser.freeze
      super
    end

    def process(context, options, argv)
      if @option_parser
        option_key = @option_key
        command_options = option_key ? {} : options

        @option_parser.order!(argv, into: command_options)

        if option_key && !command_options.empty?
          options[option_key] = command_options
        end
      else
        DEFAULT_OPTION_PARSER.order!(argv)
      end

      if argv[0] && (subcommand = @subcommands[argv[0]])
        if subcommand.is_a?(String)
          require subcommand
          subcommand = @subcommands[argv[0]]
          unless subcommand.is_a?(Command)
            raise CommandFailure, "program bug, autoload of subcommand #{argv[0]} failed"
          end
        end

        argv.shift
        subcommand.process(context, options, argv)
      elsif run_block
        if valid_args?(argv)
          befores.each do |before|
            context.instance_exec(argv, options, &before)
          end

          if @num_args.is_a?(Integer)
            context.instance_exec(*argv, options, &run_block)
          else
            context.instance_exec(argv, options, &run_block)
          end
        else
          raise CommandFailure, "invalid number of arguments#{subcommand_name} (accepts: #{@num_args}, given: #{argv.length})"
        end
      elsif @subcommands.empty?
        raise CommandFailure, "program bug, no run block or subcommands defined#{subcommand_name}"
      else
        raise CommandFailure, "invalid subcommand #{argv[0]}, valid subcommands#{subcommand_name} are: #{@subcommands.keys.sort.join(" ")}"
      end
    rescue ::OptionParser::InvalidOption
      if @option_parser
        raise CommandFailure, @option_parser.to_s
      else
        raise
      end
    end

    def befores
      if @before
        (@befores + [@before]).freeze
      else
        @befores
      end
    end

    def each_subcommand(names = [], &block)
      yield names, self
      @subcommands.each do |name, command|
        command.each_subcommand(names + [name], &block)
      end
    end

    private

    def subcommand_name
      if @command_name.empty?
        " for command"
      else
        " for #{@command_name} subcommand"
      end
    end

    def valid_args?(argv)
      if @num_args.is_a?(Integer)
        argv.length == @num_args
      else
        @num_args.include?(argv.length)
      end
    end
  end

  class Processor
    attr_reader :command

    def initialize(command)
      @command = command
    end

    def process(argv, options: {}, context: nil)
      @command.process(context, options, argv)
    end

    def on(*command_names, command_name, &block)
      dsl(command_names).on(command_name, &block)
    end

    def is(*command_names, command_name, args: 0, &block)
      dsl(command_names).is(command_name, args:, &block)
    end

    def freeze
      command.freeze
      super
    end

    def usages
      usages = {}

      command.each_subcommand do |names, command|
        if command.option_parser
          usages[names.join(" ")] = command.option_parser.to_s
        end
      end

      usages
    end

    private

    def dsl(command_names)
      command = self.command
      command_names.each do |name|
        command = command.subcommands.fetch(name)
      end
      DSL.new(command)
    end
  end
end
