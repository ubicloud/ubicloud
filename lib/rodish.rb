# frozen_string_literal: true

require "optparse"

module Rodish
  def self.processor(&block)
    Processor.new(DSL.command([].freeze, &block))
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
    def self.command(command_path, &block)
      command = Command.new(command_path)
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

    def args(args, invalid_args_message: nil)
      @command.num_args = args
      @command.invalid_args_message = invalid_args_message
    end

    def autoload_subcommand_dir(base)
      _autoload_subcommand_dir(@command.subcommands, base)
    end

    def autoload_post_subcommand_dir(base)
      _autoload_subcommand_dir(@command.post_subcommands, base)
    end

    def on(command_name, &block)
      _on(@command.subcommands, command_name, &block)
    end

    def run_on(command_name, &block)
      _on(@command.post_subcommands, command_name, &block)
    end

    def run(&block)
      @command.run_block = block
    end

    def is(command_name, args: 0, invalid_args_message: nil, &block)
      _is(:on, command_name, args:, invalid_args_message:, &block)
    end

    def run_is(command_name, args: 0, invalid_args_message: nil, &block)
      _is(:run_on, command_name, args:, invalid_args_message:, &block)
    end

    private

    def _autoload_subcommand_dir(hash, base)
      Dir.glob("*.rb", base:).each do |filename|
        hash[filename.chomp(".rb")] = File.expand_path(File.join(base, filename))
      end
    end

    def _is(meth, command_name, args:, invalid_args_message: nil, &block)
      public_send(meth, command_name) do
        args(args, invalid_args_message:)
        run(&block)
      end
    end

    def _on(hash, command_name, &block)
      command_path = @command.command_path + [command_name]
      hash[command_name] = DSL.command(command_path.freeze, &block)
    end
  end

  class Command
    attr_reader :subcommands
    attr_reader :post_subcommands

    attr_accessor :run_block
    attr_accessor :command_path
    attr_accessor :option_parser
    attr_accessor :option_key
    attr_accessor :before
    attr_accessor :num_args
    attr_accessor :invalid_args_message

    def initialize(command_path)
      # Development assertions:
      # raise "command path not frozen" unless command_path.frozen?
      # raise "befores not frozen" unless befores.frozen?
      @command_path = command_path
      @command_name = command_path.join(" ").freeze
      @subcommands = {}
      @post_subcommands = {}
      @num_args = 0
    end

    def freeze
      @subcommands.each_value(&:freeze)
      @subcommands.freeze
      @post_subcommands.each_value(&:freeze)
      @post_subcommands.freeze
      @option_parser.freeze
      super
    end

    def run_post_subcommand(context, options, argv)
      if argv[0] && @post_subcommands[argv[0]]
        process_subcommand(@post_subcommands, context, options, argv)
      else
        raise CommandFailure, "invalid post subcommand #{argv[0]}, valid post subcommands#{subcommand_name} are: #{@post_subcommands.keys.sort.join(" ")}"
      end
    end
    alias_method :run, :run_post_subcommand

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

      if argv[0] && @subcommands[argv[0]]
        process_subcommand(@subcommands, context, options, argv)
      elsif run_block
        if valid_args?(argv)
          context.instance_exec(argv, options, &before) if before

          if @num_args.is_a?(Integer)
            context.instance_exec(*argv, options, self, &run_block)
          else
            context.instance_exec(argv, options, self, &run_block)
          end
        elsif @invalid_args_message
          raise CommandFailure, "invalid arguments#{subcommand_name} (#{@invalid_args_message})"
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

    def each_subcommand(names = [], &block)
      yield names, self
      @subcommands.each do |name, command|
        command.each_subcommand(names + [name], &block)
      end
    end

    private

    def process_subcommand(subcommands, context, options, argv)
      subcommand = subcommands[argv[0]]

      if subcommand.is_a?(String)
        require subcommand
        subcommand = subcommands[argv[0]]
        unless subcommand.is_a?(Command)
          raise CommandFailure, "program bug, autoload of subcommand #{argv[0]} failed"
        end
      end

      argv.shift
      context.instance_exec(argv, options, &before) if before
      subcommand.process(context, options, argv)
    end

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

    def on(*command_names, &block)
      if block
        command_name = command_names.pop
        dsl(command_names).on(command_name, &block)
      else
        dsl(command_names)
      end
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
