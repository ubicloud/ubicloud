# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe AccessLogFilter do
  let(:io) { StringIO.new }
  let(:filter) { described_class.new(io) }

  def line(request, status)
    %(1.2.3.4 - - [10/Nov/2026:11:46:41 +0000] "#{request} HTTP/1.1" #{status} 62 0.0083\n)
  end

  it "drops successful GitHub webhook and runtime cache requests" do
    filter.write(line("POST /webhook/github", 200))
    filter.write(line("GET /runtime/github/cache?keys=abc&version=1", 204))
    filter.write(line("POST /runtime/github/caches", 201))
    filter.write(line("PATCH /runtime/github/caches/1", 302))
    expect(io.string).to be_empty
  end

  it "keeps failed requests on those paths and all other requests" do
    lines = [
      line("POST /webhook/github", 500),
      line("GET /runtime/github/cache?keys=abc", 404),
      line("POST /webhook/githubx", 200),
      line("GET /project/pj1/vm", 200),
    ]
    lines.each { filter.write(it) }
    expect(io.string).to eq lines.join
  end
end
