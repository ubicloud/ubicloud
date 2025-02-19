# frozen_string_literal: true

RSpec.describe Rodish do
  let(:base_app) do
    c = Class.new(Array)

    described_class.processor(c) do
      options "example [options] [subcommand [subcommand_options] [...]]" do
        on("-v", "top verbose output")
        on("--version", "show program version") { halt "0.0.0" }
        on("--help", "show program help") { halt to_s }
      end

      # Rubocop incorrectly believes these before blocks are related to rspec examples,
      # when they are rodish hooks.  Rubocop's auto correction breaks this Rodish processor
      # unless this cop is disabled.
      # rubocop:disable RSpec/ScatteredSetup
      before do
        push :top
      end

      on "a" do
        before do
          push :before_a
        end

        options "example a [options] [subcommand [subcommand_options] [...]]", key: :a do
          on("-v", "a verbose output")
        end

        on "b" do
          before do
            push :before_b
          end

          options "example a b [options] arg [...]", key: :b do
            on("-v", "b verbose output")
          end

          args(1...)

          run do |args, opts|
            push [:b, args, opts]
          end
        end

        args 2, invalid_args_message: "accepts: x y"
        run do |x, y|
          push [:a, x, y]
        end
      end

      is "c" do
        push :c
      end

      is "d", args: 1 do |d|
        push [:d, d]
      end

      on "e" do
        on "f" do
          run do
            push :f
          end
        end
      end

      on "g" do
        post_options "example g arg [options] [subcommand [subcommand_options] [...]]", key: :g do
          on("-v", "g verbose output")
          on("-k", "--key=foo", "set key")
          wrap("Foo:", %w[bar baz quux options subcommand subcommand_options], limit: 23)
        end

        args(2...)

        is "j" do
          push :j
        end

        run_is "h" do |opts|
          push [:h, opts.dig(:g, :v), opts.dig(:g, :key)]
        end

        run_on "i" do
          before do |_, opts|
            push opts.dig(:g, :v)
            push opts.dig(:g, :key)
          end
          # rubocop:enable RSpec/ScatteredSetup

          is "k" do
            push :k
          end

          run do
            push :i
          end
        end

        run do |(x, *argv), opts, command|
          push [:g, x]
          command.run(self, opts, argv)
        end
      end

      on "l" do
        skip_option_parsing "example l"

        args(0...)

        run do |argv|
          push [:l, argv]
        end
      end

      run do
        push :empty
      end
    end

    c
  end

  [true, false].each do |frozen|
    context "when #{"not " unless frozen}frozen" do
      let(:app) do
        app = base_app
        app.freeze if frozen
        app
      end

      it "executes expected command code in expected order" do
        expect(app.process([])).to eq [:top, :empty]
        expect(app.process(%w[a b 1])).to eq [:top, :before_a, :before_b, [:b, %w[1], {a: {}, b: {}}]]
        expect(app.process(%w[a b 1 2])).to eq [:top, :before_a, :before_b, [:b, %w[1 2], {a: {}, b: {}}]]
        expect(app.process(%w[a 3 4])).to eq [:top, :before_a, [:a, "3", "4"]]
        expect(app.process(%w[c])).to eq [:top, :c]
        expect(app.process(%w[d 5])).to eq [:top, [:d, "5"]]
        expect(app.process(%w[e f])).to eq [:top, :f]
      end

      it "supports run_on/run_is for subcommands dispatched to during run" do
        expect(app.process(%w[g j])).to eq [:top, :j]
        expect(app.process(%w[g 1 h])).to eq [:top, [:g, "1"], [:h, nil, nil]]
        expect(app.process(%w[g 1 i])).to eq [:top, [:g, "1"], nil, nil, :i]
        expect(app.process(%w[g 1 i k])).to eq [:top, [:g, "1"], nil, nil, :k]
      end

      it "supports post options for commands, parsed before subcommand dispatching" do
        expect(app.process(%w[g 1 -v h])).to eq [:top, [:g, "1"], [:h, true, nil]]
        expect(app.process(%w[g 1 -v i])).to eq [:top, [:g, "1"], true, nil, :i]
        expect(app.process(%w[g 1 -v i k])).to eq [:top, [:g, "1"], true, nil, :k]
        expect(app.process(%w[g 1 -k 2 h])).to eq [:top, [:g, "1"], [:h, nil, "2"]]
        expect(app.process(%w[g 1 -k 2 i])).to eq [:top, [:g, "1"], nil, "2", :i]
        expect(app.process(%w[g 1 -k 2 i k])).to eq [:top, [:g, "1"], nil, "2", :k]
      end

      it "supports skipping option parsing" do
        expect(app.process(%w[l -A 1 b])).to eq [:top, [:l, %w[-A 1 b]]]
      end

      it "handles invalid subcommands dispatched to during run" do
        expect { app.process(%w[g 1 l]) }.to raise_error(Rodish::CommandFailure, "invalid post subcommand: l")
      end

      it "handles options at any level they are defined" do
        expect(app.process(%w[-v a b -v 1 2])).to eq [:top, :before_a, :before_b, [:b, %w[1 2], {a: {}, b: {v: true}, v: true}]]
        expect(app.process(%w[a -v b 1 2])).to eq [:top, :before_a, :before_b, [:b, %w[1 2], {a: {v: true}, b: {}}]]
      end

      it "raises CommandFailure when there a command has no command block or subcommands" do
        app = described_class.processor(Class.new) {}
        expect { app.process([]) }.to raise_error(Rodish::CommandFailure, "program bug, no run block or subcommands defined for command")
        app = described_class.processor(Class.new) do
          on("f") {}
        end
        expect { app.process(%w[f]) }.to raise_error(Rodish::CommandFailure, "program bug, no run block or subcommands defined for f subcommand")
      end

      it "raises CommandFailure for unexpected post options" do
        expect { app.process(%w[g 1 -b h]) }.to raise_error(Rodish::CommandFailure, "invalid option: -b")
      end

      it "raises CommandExit for blocks that use halt" do
        expect { app.process(%w[--version]) }.to raise_error(Rodish::CommandExit, "0.0.0")
        expect { app.process(%w[--help]) }.to raise_error(Rodish::CommandExit, <<~USAGE)
          Usage: example [options] [subcommand [subcommand_options] [...]]

          Options:
              -v                               top verbose output
                  --version                    show program version
                  --help                       show program help

          Subcommands: a c d e g l
        USAGE
      end

      it "has options_text return nil if there are no option parsers for the command" do
        expect(app.command.subcommand("d").options_text).to be_nil
      end

      it "can get usages for all options" do
        usages = app.usages
        expect(usages.length).to eq 5
        expect(usages[""]).to eq <<~USAGE
          Usage: example [options] [subcommand [subcommand_options] [...]]

          Options:
              -v                               top verbose output
                  --version                    show program version
                  --help                       show program help

          Subcommands: a c d e g l
        USAGE
        expect(usages["a"]).to eq <<~USAGE
          Usage: example a [options] [subcommand [subcommand_options] [...]]

          Options:
              -v                               a verbose output

          Subcommands: b
        USAGE
        expect(usages["a b"]).to eq <<~USAGE
          Usage: example a b [options] arg [...]

          Options:
              -v                               b verbose output
        USAGE
        expect(usages["g"]).to eq <<~USAGE
          Usage: example g arg [options] [subcommand [subcommand_options] [...]]

          Options:
              -v                               g verbose output
              -k, --key=foo                    set key
          Foo: bar baz quux
               options subcommand
               subcommand_options

          Subcommands: h i
        USAGE
        expect(usages["l"]).to eq "Usage: example l\n"
      end

      next if frozen

      describe "failure handling" do
        let(:res) { [] }

        before do
          res = self.res
          app.define_singleton_method(:new) { res.clear }
        end

        it "raises CommandFailure for unexpected number of arguments without executing code" do
          expect { app.process(%w[6]) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for command (accepts: 0, given: 1)")
          expect(res).to be_empty
          expect { app.process(%w[a b]) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for a b subcommand (accepts: 1..., given: 0)")
          expect(res).to eq [:top, :before_a]
          expect { app.process(%w[a]) }.to raise_error(Rodish::CommandFailure, "invalid arguments for a subcommand (accepts: x y)")
          expect(res).to eq [:top]
          expect { app.process(%w[a 1]) }.to raise_error(Rodish::CommandFailure, "invalid arguments for a subcommand (accepts: x y)")
          expect(res).to eq [:top]
          expect { app.process(%w[a 1 2 3]) }.to raise_error(Rodish::CommandFailure, "invalid arguments for a subcommand (accepts: x y)")
          expect(res).to eq [:top]
          expect { app.process(%w[c 1]) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for c subcommand (accepts: 0, given: 1)")
          expect(res).to eq [:top]
          expect { app.process(%w[d]) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for d subcommand (accepts: 1, given: 0)")
          expect(res).to eq [:top]
          expect { app.process(%w[d 1 2]) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for d subcommand (accepts: 1, given: 2)")
          expect(res).to eq [:top]
        end

        it "raises CommandFailure for missing subcommand" do
          expect { app.process(%w[e]) }.to raise_error(Rodish::CommandFailure, "no subcommand provided")
          expect(res).to eq [:top]
        end

        it "raises CommandFailure for invalid subcommand" do
          expect { app.process(%w[e g]) }.to raise_error(Rodish::CommandFailure, "invalid subcommand: g")
          expect(res).to eq [:top]

          app = described_class.processor(Class.new) do
            on("f") {}
          end
          expect { app.process(%w[g]) }.to raise_error(Rodish::CommandFailure, "invalid subcommand: g")
        end

        it "raises CommandFailure for unexpected options" do
          expect { app.process(%w[-d]) }.to raise_error(Rodish::CommandFailure, "invalid option: -d")
          expect(res).to be_empty
          expect { app.process(%w[a -d]) }.to raise_error(Rodish::CommandFailure, "invalid option: -d")
          expect(res).to eq [:top]
          expect { app.process(%w[a b -d]) }.to raise_error(Rodish::CommandFailure, "invalid option: -d")
          expect(res).to eq [:top, :before_a]
          expect { app.process(%w[d -d 1 2]) }.to raise_error(Rodish::CommandFailure, "invalid option: -d")
          expect(res).to eq [:top]
        end

        it "supports adding subcommands after initialization" do
          expect { app.process(%w[z]) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for command (accepts: 0, given: 1)")
          expect(res).to be_empty

          app.on("z") do
            args 1
            run do |arg|
              push [:z, arg]
            end
          end
          app.process(%w[z h])
          expect(res).to eq [:top, [:z, "h"]]

          app.on("z", "y") do
            run do
              push :y
            end
          end
          app.process(%w[z y])
          expect(res).to eq [:top, :y]

          app.is("z", "y", "x", args: 1) do |arg|
            push [:x, arg]
          end
          app.process(%w[z y x j])
          expect(res).to eq [:top, [:x, "j"]]
        end

        it "supports autoloading" do
          main = TOPLEVEL_BINDING.receiver
          main.instance_variable_set(:@ExampleRodish, app)
          app.on("k") do
            autoload_subcommand_dir("spec/lib/rodish-example")
            autoload_post_subcommand_dir("spec/lib/rodish-example-post")

            args(2...)
            run do |(x, *argv), opts, command|
              push [:k, x]
              command.run(self, opts, argv)
            end
          end

          app.process(%w[k m])
          expect(res).to eq [:top, :m]

          app.process(%w[k 1 o])
          expect(res).to eq [:top, [:k, "1"], :o]

          expect { app.process(%w[k n]) }.to raise_error(Rodish::CommandFailure, "program bug, autoload of subcommand n failed")
        ensure
          main.remove_instance_variable(:@ExampleRodish)
        end
      end

      it "uses separate lines for more than 6 subcommands" do
        subcommands = %w[a b c d e f g]
        app.on("z") do
          options "example z subcommand"
          subcommands.each do |cmd|
            is(cmd) {}
          end
        end
        expect(app.command.subcommand("z").options_text).to eq <<~USAGE
          Usage: example z subcommand

          Subcommands:
            a
            b
            c
            d
            e
            f
            g
        USAGE
      end
    end
  end
end
