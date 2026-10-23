# frozen_string_literal: true

module TerraformHarness
  # Rack middleware that lets specs hold matching in-flight HTTP requests
  # at a barrier. The spec registers a gate, runs terraform on a
  # background thread, waits for the matching request to arrive (it
  # blocks inside a puma worker before reaching the app), mutates the
  # DB / advances strands from the spec thread, then releases the gate.
  # The DB is the only clock: nothing proceeds until the spec says so.
  class RequestGate
    class Gate
      attr_reader :held_env

      def initialize(method: nil, path: nil)
        @method = method
        @path = path
        @arrived = Queue.new
        @release = Queue.new
        @consumed = false
        @mutex = Mutex.new
      end

      # Soundness sentinel support: a non-consuming match test and the
      # held (consumed, not yet released) state.
      def matches?(env)
        return false if @method && env["REQUEST_METHOD"] != @method
        return false if @path && !@path.match?(env["PATH_INFO"])
        true
      end

      def held? = @consumed && !released?

      # One-shot: each gate holds exactly one request.
      def try_consume(env)
        @mutex.synchronize do
          return false if @consumed
          return false if @method && env["REQUEST_METHOD"] != @method
          return false if @path && !@path.match?(env["PATH_INFO"])
          @consumed = true
        end
        true
      end

      # Called from the puma worker thread; blocks until released.
      def hold!(env)
        @held_env = env.slice("REQUEST_METHOD", "PATH_INFO", "QUERY_STRING")
        @arrived << true
        @release.pop
      end

      # Called from the spec thread.
      def wait_for_arrival(timeout: 10)
        @arrived.pop(timeout:) or
          raise "request gate timed out waiting for #{@method} #{@path.inspect}"
        self
      end

      def release(corrupt: nil)
        @corrupt = corrupt
        @release << true
        self
      end

      attr_reader :corrupt

      def released? = @release.closed? || @release.empty?

      # Unblock a held worker unconditionally (suite hygiene).
      def force_release
        @release << true
      end
    end

    def initialize(app)
      @app = app
      @mutex = Mutex.new
      @gates = []
    end

    def register(method: nil, path: nil)
      gate = Gate.new(method:, path:)
      @mutex.synchronize { @gates << gate }
      gate
    end

    # Between examples: release anything still held so no puma worker
    # stays parked, then forget all gates.
    def violations = @mutex.synchronize { (@violations || []).dup }
    def arrivals = @mutex.synchronize { (@arrivals || []).dup }

    def clear!
      @mutex.synchronize do
        forced = @gates.count(&:held?)
        @gates.each(&:force_release)
        @gates.clear
        @arrivals&.clear
        @violations&.clear
        forced
      end
    end

    MUTATING = %w[POST PUT PATCH DELETE].freeze

    def call(env)
      gate = @mutex.synchronize { @gates.find { it.try_consume(env) } }
      if MUTATING.include?(env["REQUEST_METHOD"])
        record = {t: Process.clock_gettime(Process::CLOCK_MONOTONIC),
                  m: env["REQUEST_METHOD"], path: env["PATH_INFO"],
                  held_by_gate: !gate.nil?}
        @mutex.synchronize do
          (@arrivals ||= []) << record
          @arrivals.shift while @arrivals.length > 200
          # The barrier invariant, machine-checked: while a one-shot
          # gate holds a request, a SECOND matching mutation reaching
          # the app is exactly the ghost-writer that would make every
          # barrier assertion theater. Record it with full context.
          if gate.nil? && (ghost = @gates.find { it.held? && it.matches?(env) })
            (@violations ||= []) << record.merge(
              held_gate: {method: ghost.instance_variable_get(:@method),
                          path: ghost.instance_variable_get(:@path).inspect,
                          held_env: ghost.instance_variable_get(:@held_env)},
            )
          end
        end
      end
      gate&.hold!(env)
      response = @app.call(env)
      if gate&.corrupt == :empty_body
        # The request went through (row committed); the client sees a
        # bodyless 200 - the deterministic ambiguous create.
        return [200, {"content-type" => "application/json"}, [""]]
      end
      response
    end
  end
end
