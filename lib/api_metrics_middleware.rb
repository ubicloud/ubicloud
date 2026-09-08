# frozen_string_literal: true

# Times every request into ApiMetrics, labeled with the operation the
# route set in clover.api_operation.
class ApiMetricsMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    # Internal SDK dispatches (ubi_cli) re-enter the middleware with the outer
    # request's env merged in; time only the outermost call.
    return @app.call(env) if env["clover.api_metrics.timed"]
    env["clover.api_metrics.timed"] = true

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      response = @app.call(env)
    rescue Exception # rubocop:disable Lint/RescueException
      observe(env, "500", started_at)
      raise
    end
    observe(env, response[0].to_s, started_at)
    response
  end

  private

  def observe(env, code, started_at)
    return unless (handler = env["clover.api_operation"])

    ApiMetrics.observe(
      handler:,
      method: env["REQUEST_METHOD"],
      code:,
      duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at,
    )
  rescue => e
    # Telemetry is best-effort: never replace the response or an in-flight exception.
    Clog.emit("api metrics record failed", Util.exception_to_hash(e))
  end
end
