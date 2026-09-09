# frozen_string_literal: true

require_relative "../spec_helper"
require "rack/lint"
require "rack/mock_request"

RSpec.describe ApiMetricsMiddleware do
  def simulate(inner_app, url:, method: "GET", extra_env: {})
    stack = Rack::Lint.new(described_class.new(Rack::Lint.new(inner_app)))
    Rack::MockRequest.new(stack).request(method, url, extra_env.dup)
  end

  def sample_count(handler:, code:, method: "GET")
    ApiMetrics.request_duration.get(labels: {handler:, method:, code:}).fetch("+Inf")
  end

  it "records a sample labeled with the operation set during routing" do
    labeling_app = lambda do |env|
      env["clover.api_operation"] = "/spec/labeled-operation"
      [200, {"content-type" => "text/plain"}, ["ok"]]
    end
    expect { simulate(labeling_app, url: "http://api.example.com/spec") }
      .to change { sample_count(handler: "/spec/labeled-operation", code: "200") }.by(1)
  end

  it "does not record requests with no operation set" do
    not_found_app = ->(env) { [404, {"content-type" => "text/plain"}, ["not found"]] }
    expect(ApiMetrics.request_duration).not_to receive(:observe)
    expect(simulate(not_found_app, url: "http://api.example.com/spec-unlabeled").status).to eq 404
  end

  it "records a 500 sample and re-raises when the app raises" do
    raising_app = lambda do |env|
      env["clover.api_operation"] = "/spec/raising-operation"
      raise "boom"
    end
    expect { simulate(raising_app, url: "http://api.example.com/spec") }
      .to raise_error("boom")
      .and change { sample_count(handler: "/spec/raising-operation", code: "500") }.by(1)
  end

  it "does not double-count internal dispatches that were already timed" do
    labeled_app = lambda do |env|
      env["clover.api_operation"] = "/spec/inner-operation"
      [200, {"content-type" => "text/plain"}, ["ok"]]
    end
    response = nil
    expect { response = simulate(labeled_app, url: "http://api.example.com/spec", extra_env: {"clover.api_metrics.timed" => true}) }
      .not_to change { sample_count(handler: "/spec/inner-operation", code: "200") }
    expect(response.status).to eq 200
  end

  it "serves the response even when recording the sample fails" do
    labeled_app = lambda do |env|
      env["clover.api_operation"] = "/spec/failing-operation"
      [200, {"content-type" => "text/plain"}, ["ok"]]
    end
    expect(ApiMetrics.request_duration).to receive(:observe).and_raise(Errno::ENOSPC)
    expect(Clog).to receive(:emit).with("api metrics record failed", Hash).and_call_original
    expect(simulate(labeled_app, url: "http://api.example.com/spec").status).to eq 200
  end
end
