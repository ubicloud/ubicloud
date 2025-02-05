# frozen_string_literal: true

RSpec.describe Rodish do
  let(:base_app) do
    described_class.processor do
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
          # rubocop:enable RSpec/ScatteredSetup

          options "example a b [options] arg [...]", key: :b do
            on("-v", "b verbose output")
          end

          args(1...)

          run do |args, opts|
            push [:b, args, opts]
          end
        end

        args 2
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
        args(2...)

        is "j" do
          push :j
        end

        run_is "h" do
          push :h
        end

        run_on "i" do
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

      run do
        push :empty
      end
    end
  end

  [true, false].each do |frozen|
    context "when #{"not " unless frozen}frozen" do
      let(:app) do
        app = base_app
        app.freeze if frozen
        app
      end

      it "executes expected command code in expected order" do
        res = []
        app.process([], context: res.clear)
        expect(res).to eq [:top, :empty]
        app.process(%w[a b 1], context: res.clear)
        expect(res).to eq [:top, :before_a, :before_b, [:b, %w[1], {}]]
        app.process(%w[a b 1 2], context: res.clear)
        expect(res).to eq [:top, :before_a, :before_b, [:b, %w[1 2], {}]]
        app.process(%w[a 3 4], context: res.clear)
        expect(res).to eq [:top, :before_a, [:a, "3", "4"]]
        app.process(%w[c], context: res.clear)
        expect(res).to eq [:top, :c]
        app.process(%w[d 5], context: res.clear)
        expect(res).to eq [:top, [:d, "5"]]
        app.process(%w[e f], context: res.clear)
        expect(res).to eq [:top, :f]
      end

      it "supports run_on/run_is for subcommands dispatched to during run" do
        res = []
        app.process(%w[g j], context: res.clear)
        expect(res).to eq [:top, :j]
        app.process(%w[g 1 h], context: res.clear)
        expect(res).to eq [:top, [:g, "1"], :h]
        app.process(%w[g 1 i], context: res.clear)
        expect(res).to eq [:top, [:g, "1"], :i]
        app.process(%w[g 1 i k], context: res.clear)
        expect(res).to eq [:top, [:g, "1"], :k]
      end

      it "handles invalid subcommands dispatched to during run" do
        res = []
        expect { app.process(%w[g 1 l], context: res) }.to raise_error(Rodish::CommandFailure, "invalid post subcommand l, valid post subcommands for g subcommand are: h i")
      end

      it "handles options at any level they are defined" do
        res = []
        app.process(%w[-v a b -v 1 2], context: res.clear)
        expect(res).to eq [:top, :before_a, :before_b, [:b, %w[1 2], {b: {v: true}, v: true}]]
        app.process(%w[a -v b 1 2], context: res.clear)
        expect(res).to eq [:top, :before_a, :before_b, [:b, %w[1 2], {a: {v: true}}]]
      end

      it "raises CommandFailure for unexpected number of arguments without executing code" do
        res = []
        expect { app.process(%w[6], context: res) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for command (accepts: 0, given: 1)")
        expect(res).to be_empty
        expect { app.process(%w[a b], context: res) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for a b subcommand (accepts: 1..., given: 0)")
        expect(res).to eq [:top, :before_a]
        expect { app.process(%w[a], context: res.clear) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for a subcommand (accepts: 2, given: 0)")
        expect(res).to eq [:top]
        expect { app.process(%w[a 1], context: res.clear) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for a subcommand (accepts: 2, given: 1)")
        expect(res).to eq [:top]
        expect { app.process(%w[a 1 2 3], context: res.clear) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for a subcommand (accepts: 2, given: 3)")
        expect(res).to eq [:top]
        expect { app.process(%w[c 1], context: res.clear) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for c subcommand (accepts: 0, given: 1)")
        expect(res).to eq [:top]
        expect { app.process(%w[d], context: res.clear) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for d subcommand (accepts: 1, given: 0)")
        expect(res).to eq [:top]
        expect { app.process(%w[d 1 2], context: res.clear) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for d subcommand (accepts: 1, given: 2)")
        expect(res).to eq [:top]
      end

      it "raises CommandFailure for invalid subcommand" do
        res = []
        expect { app.process(%w[e g], context: res) }.to raise_error(Rodish::CommandFailure, "invalid subcommand g, valid subcommands for e subcommand are: f")
        expect(res).to eq [:top]

        app = described_class.processor do
          on("f") {}
        end
        expect { app.process(%w[g], context: res.clear) }.to raise_error(Rodish::CommandFailure, "invalid subcommand g, valid subcommands for command are: f")
        expect(res).to be_empty
      end

      it "raises CommandFailure when there a command has no command block or subcommands" do
        app = described_class.processor {}
        expect { app.process([]) }.to raise_error(Rodish::CommandFailure, "program bug, no run block or subcommands defined for command")
        app = described_class.processor do
          on("f") {}
        end
        expect { app.process(%w[f]) }.to raise_error(Rodish::CommandFailure, "program bug, no run block or subcommands defined for f subcommand")
      end

      it "raises CommandFailure for unexpected options" do
        res = []
        expect { app.process(%w[-d], context: res) }.to raise_error(Rodish::CommandFailure, /top verbose output/)
        expect(res).to be_empty
        expect { app.process(%w[a -d], context: res) }.to raise_error(Rodish::CommandFailure, /a verbose output/)
        expect(res).to eq [:top]
        expect { app.process(%w[a b -d], context: res.clear) }.to raise_error(Rodish::CommandFailure, /b verbose output/)
        expect(res).to eq [:top, :before_a]
        expect { app.process(%w[d -d 1 2], context: res.clear) }.to raise_error(Rodish::CommandFailure, /top verbose output/)
        expect(res).to eq [:top]
      end

      it "raises CommandExit for blocks that use halt" do
        expect { app.process(%w[--version]) }.to raise_error(Rodish::CommandExit, "0.0.0")
        expect { app.process(%w[--help]) }.to raise_error(Rodish::CommandExit, <<~USAGE)
          Usage: example [options] [subcommand [subcommand_options] [...]]

          Options:
              -v                               top verbose output
                  --version                    show program version
                  --help                       show program help

          Subcommands: a c d e g
        USAGE
      end

      it "can get usages for all options" do
        usages = app.usages
        expect(usages.length).to eq 3
        expect(usages[""]).to eq <<~USAGE
          Usage: example [options] [subcommand [subcommand_options] [...]]

          Options:
              -v                               top verbose output
                  --version                    show program version
                  --help                       show program help

          Subcommands: a c d e g
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
      end

      unless frozen
        it "supports adding subcommands after initialization" do
          res = []
          expect { app.process(%w[z], context: res) }.to raise_error(Rodish::CommandFailure, "invalid number of arguments for command (accepts: 0, given: 1)")
          expect(res).to be_empty

          app.on("z") do
            args 1
            run do |arg|
              push [:z, arg]
            end
          end
          app.process(%w[z h], context: res.clear)
          expect(res).to eq [:top, [:z, "h"]]

          app.on("z", "y") do
            run do
              push :y
            end
          end
          app.process(%w[z y], context: res.clear)
          expect(res).to eq [:top, :y]

          app.is("z", "y", "x", args: 1) do |arg|
            push [:x, arg]
          end
          app.process(%w[z y x j], context: res.clear)
          expect(res).to eq [:top, [:x, "j"]]
        end

        it "supports autoloading" do
          main = TOPLEVEL_BINDING.receiver
          main.instance_variable_set(:@ExampleRodish, app)
          app.on("k") do
            autoload_subcommand_dir("spec/lib/rodish-example")
          end

          res = []
          app.process(%w[k m], context: res.clear)
          expect(res).to eq [:top, :m]

          expect { app.process(%w[k n], context: res) }.to raise_error(Rodish::CommandFailure, "program bug, autoload of subcommand n failed")
        ensure
          main.remove_instance_variable(:@ExampleRodish)
        end
      end
    end
  end
end
