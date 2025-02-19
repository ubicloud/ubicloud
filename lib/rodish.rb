# frozen_string_literal: true

require "optparse"

module Rodish
  def self.processor(mod, &block)
    mod.extend(Processor)
    mod.instance_variable_set(:@command, DSL.command([].freeze, &block))
    mod
  end

  class CommandExit < StandardError
    def failure?
      false
    end
  end

  class CommandFailure < CommandExit
    def initialize(message, option_parsers = [])
      option_parsers = [option_parsers] unless option_parsers.is_a?(Array)
      @option_parsers = option_parsers.compact
      super(message)
    end

    def failure?
      true
    end

    def message_with_usage
      if @option_parsers.empty?
        message
      else
        "#{message}\n\n#{@option_parsers.join("\n\n")}"
      end
    end
  end

  class ProgramBug < CommandFailure
  end

  class OptionParser < ::OptionParser
    attr_accessor :subcommands

    # Don't add officious, which includes options that call exit
    def add_officious
    end

    def to_s
      string = super

      if subcommands.length > 6
        string += "\nSubcommands:\n  #{subcommands.keys.sort.join("\n  ")}\n"
      elsif !subcommands.empty?
        string += "\nSubcommands: #{subcommands.keys.sort.join(" ")}\n"
      end

      string
    end

    def wrap(prefix, values, separator: " ", limit: 80)
      line = [prefix]
      lines = [line]
      prefix_length = length = prefix.length
      sep_length = separator.length
      indent = " " * prefix_length

      values.each do |value|
        value_length = value.length
        new_length = sep_length + length + value_length
        if new_length > limit
          line = [indent, separator, value]
          lines << line
          length = prefix_length
        else
          line << separator << value
        end
        length += sep_length + value_length
      end

      lines.each do |line|
        separator line.join
      end
    end

    def halt(string)
      raise CommandExit, string
    end
  end

  option_parser = DEFAULT_OPTION_PARSER = OptionParser.new
  option_parser.set_banner("")
  option_parser.freeze

  class SkipOptionParser
    attr_reader :banner
    attr_reader :to_s

    def initialize(banner)
      @banner = "Usage: #{banner}"
      @to_s = @banner + "\n"
    end
  end

  class DSL
    def self.command(command_path, &block)
      command = Command.new(command_path)
      new(command).instance_exec(&block)
      command
    end

    def initialize(command)
      @command = command
    end

    def skip_option_parsing(banner)
      @command.option_parser = SkipOptionParser.new(banner)
    end

    def options(banner, key: nil, &block)
      @command.option_key = key
      @command.option_parser = create_option_parser(banner, @command.subcommands, &block)
    end

    def post_options(banner, key: nil, &block)
      @command.post_option_key = key
      @command.post_option_parser = create_option_parser(banner, @command.post_subcommands, &block)
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

    def create_option_parser(banner, subcommands, &block)
      option_parser = OptionParser.new
      option_parser.set_banner("Usage: #{banner}")
      if block
        option_parser.separator ""
        option_parser.separator "Options:"
        option_parser.instance_exec(&block)
      end
      option_parser.subcommands = subcommands
      option_parser
    end
  end

  class Command
    attr_reader :subcommands
    attr_reader :post_subcommands

    attr_accessor :run_block
    attr_accessor :command_path
    attr_accessor :option_parser
    attr_accessor :option_key
    attr_accessor :post_option_parser
    attr_accessor :post_option_key
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
      begin
        process_options(argv, options, @post_option_key, @post_option_parser)
      rescue ::OptionParser::InvalidOption => e
        raise CommandFailure.new(e.message, @post_option_parser)
      end

      arg = argv[0]
      if arg && @post_subcommands[arg]
        process_subcommand(@post_subcommands, context, options, argv)
      else
        process_command_failure(arg, @post_subcommands, @post_option_parser, "post ")
      end
    end
    alias_method :run, :run_post_subcommand

    def process(context, options, argv)
      process_options(argv, options, @option_key, @option_parser)

      arg = argv[0]
      if argv && @subcommands[arg]
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
          raise_failure("invalid arguments#{subcommand_name} (#{@invalid_args_message})")
        else
          raise_failure("invalid number of arguments#{subcommand_name} (accepts: #{@num_args}, given: #{argv.length})")
        end
      else
        process_command_failure(arg, @subcommands, @option_parser, "")
      end
    rescue ::OptionParser::InvalidOption => e
      if @option_parser || @post_option_parser
        raise_failure(e.message)
      else
        raise
      end
    end

    def each_subcommand(names = [], &block)
      yield names, self
      _each_subcommand(names, @subcommands, &block)
      _each_subcommand(names, @post_subcommands, &block)
    end

    def raise_failure(message, option_parsers = self.option_parsers)
      raise CommandFailure.new(message, option_parsers)
    end

    def options_text
      option_parsers = self.option_parsers
      unless option_parsers.empty?
        _options_text(option_parsers)
      end
    end

    def subcommand(cmd)
      _subcommand(@subcommands, cmd)
    end

    def post_subcommand(cmd)
      _subcommand(@post_subcommands, cmd)
    end

    def option_parsers
      [@option_parser, @post_option_parser].compact
    end

    private

    def _each_subcommand(names, subcommands, &block)
      subcommands.each_key do |name|
        command = _subcommand(subcommands, name)
        sc_names = names + [name]
        command.each_subcommand(sc_names, &block)
      end
    end

    def _subcommand(subcommands, cmd)
      subcommand = subcommands[cmd]

      if subcommand.is_a?(String)
        require subcommand
        subcommand = subcommands[cmd]
        unless subcommand.is_a?(Command)
          raise ProgramBug, "program bug, autoload of subcommand #{cmd} failed"
        end
      end

      subcommand
    end

    def _options_text(option_parsers)
      option_parsers.join("\n\n")
    end

    def process_command_failure(arg, subcommands, option_parser, prefix)
      if subcommands.empty?
        raise ProgramBug, "program bug, no run block or #{prefix}subcommands defined#{subcommand_name}"
      elsif arg
        raise_failure("invalid #{prefix}subcommand: #{arg}", option_parser)
      else
        raise_failure("no #{prefix}subcommand provided", option_parser)
      end
    end

    def process_options(argv, options, option_key, option_parser)
      case option_parser
      when SkipOptionParser
        # do nothing
      when nil
        DEFAULT_OPTION_PARSER.order!(argv)
      else
        command_options = option_key ? {} : options

        option_parser.order!(argv, into: command_options)

        if option_key
          options[option_key] = command_options
        end
      end
    end

    def process_subcommand(subcommands, context, options, argv)
      subcommand = _subcommand(subcommands, argv[0])
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

  module Processor
    attr_reader :command

    def process(argv, ...)
      @command.process(new(...), {}, argv)
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
        option_parsers = command.option_parsers
        unless option_parsers.empty?
          usages[names.join(" ")] = command.option_parsers.join("\n\n")
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
