#!/usr/bin/env ruby
# frozen_string_literal: true

# Age-based sweep of the GitHub cache resources the e2e suite leaves behind.
#
# A runner's first cache request creates an R2 bucket for its repository and a
# Cloudflare API token scoped to it, both named e2e-<repository ubid> in e2e
# runs (GithubRepository#bucket_name). The run deletes them when it destroys
# the repository, but a job cancelled or killed before then leaks them, and a
# leaked token counts against the account's 50-token cap. Every token and
# bucket named that way and older than STALE_AFTER is deleted here; nothing
# else in the account is touched.
#
# Expects:
#   ENV["CLOUDFLARE_API_KEY"]  -- bearer token for the Cloudflare tokens API
#   ENV["R2_ENDPOINT"]         -- S3 endpoint of the R2 account
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION -- for aws
#   ENV["DRY_RUN"]             -- 1 to report what would be deleted
#   aws is on PATH. Runs on the runner's system ruby (3.2); no Bundler or gems.

require "json"
require "net/http"
require "open3"
require "openssl"
require "time"

module GithubCacheCleanup
  TOKEN_NAME = /\Ae2e-gp[0-9a-z]{24}-token\z/
  BUCKET_NAME = /\Ae2e-gp[0-9a-z]{24}\z/
  STALE_AFTER = 24 * 60 * 60
  TOKENS_URL = "https://api.cloudflare.com/client/v4/user/tokens"

  class Error < StandardError; end

  class Cloudflare
    def initialize(api_key)
      @api_key = api_key
    end

    def tokens
      tokens = []
      page = 1
      loop do
        data = request(Net::HTTP::Get, "#{TOKENS_URL}?page=#{page}&per_page=50")
        tokens.concat(data.fetch("result"))
        break if page >= data.dig("result_info", "total_pages").to_i
        page += 1
      end
      tokens
    end

    def delete_token(id)
      request(Net::HTTP::Delete, "#{TOKENS_URL}/#{id}", gone: 404)
    end

    private

    def request(klass, url, gone: nil)
      uri = URI.parse(url)
      req = klass.new(uri)
      req["Authorization"] = "Bearer #{@api_key}"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(req) }
      return {} if gone && response.code.to_i == gone
      data = JSON.parse(response.body)
      raise Error, "#{klass::METHOD} #{uri.path} failed: HTTP #{response.code} #{data["errors"].inspect}" unless response.is_a?(Net::HTTPSuccess) && data["success"]
      data
    rescue JSON::ParserError, IOError, SocketError, SystemCallError, Net::HTTPBadResponse, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
      raise Error, "#{klass::METHOD} #{uri.path} failed: #{e.class}: #{e.message}"
    end
  end

  class R2
    GONE = /\((NoSuchBucket|NoSuchUpload|NoSuchKey)\)/

    def initialize(endpoint)
      @endpoint = endpoint
    end

    def buckets
      s3api("list-buckets").fetch("Buckets", [])
    end

    def empty_and_delete(name)
      s3api("list-multipart-uploads", "--bucket", name).fetch("Uploads", []).each do |upload|
        s3api("abort-multipart-upload", "--bucket", name, "--key", upload.fetch("Key"), "--upload-id", upload.fetch("UploadId"))
      end
      loop do
        objects = s3api("list-objects-v2", "--bucket", name).fetch("Contents", [])
        break if objects.empty?
        objects.each { |object| s3api("delete-object", "--bucket", name, "--key", object.fetch("Key")) }
      end
      s3api("delete-bucket", "--bucket", name)
    end

    private

    def s3api(*args)
      stdout, stderr, status = Open3.capture3("aws", "s3api", *args, "--endpoint-url", @endpoint, "--output", "json")
      return {} if !status.success? && GONE.match?(stderr)
      raise Error, "aws s3api #{args.first} failed: #{stderr.lines.map(&:strip).reject(&:empty?).last}" unless status.success?
      stdout.strip.empty? ? {} : JSON.parse(stdout)
    rescue JSON::ParserError => e
      raise Error, "aws s3api #{args.first} returned unparsable JSON: #{e.message}"
    end
  end

  def self.main
    dry_run = %w[1 true].include?(ENV["DRY_RUN"].to_s)
    cutoff = Time.now - STALE_AFTER
    cloudflare = Cloudflare.new(ENV.fetch("CLOUDFLARE_API_KEY"))
    r2 = R2.new(ENV.fetch("R2_ENDPOINT"))
    tally = Hash.new(0)

    tokens = cloudflare.tokens
    stale_tokens = tokens.select { |token| TOKEN_NAME.match?(token["name"]) && Time.iso8601(token["issued_on"]) < cutoff }
    puts "#{tokens.size} token(s) in the account, #{stale_tokens.size} stale e2e token(s)"
    stale_tokens.each do |token|
      puts "#{"[dry-run] " if dry_run}Delete token #{token["name"]} (issued #{token["issued_on"]})"
      cloudflare.delete_token(token["id"]) unless dry_run
      tally[:tokens] += 1
    rescue Error => e
      puts "  WARN: #{e.message}"
      tally[:failed] += 1
    end

    buckets = r2.buckets
    stale_buckets = buckets.select { |bucket| BUCKET_NAME.match?(bucket["Name"]) && Time.iso8601(bucket["CreationDate"]) < cutoff }
    puts "#{buckets.size} bucket(s) in the account, #{stale_buckets.size} stale e2e bucket(s)"
    stale_buckets.each do |bucket|
      puts "#{"[dry-run] " if dry_run}Delete bucket #{bucket["Name"]} (created #{bucket["CreationDate"]})"
      r2.empty_and_delete(bucket["Name"]) unless dry_run
      tally[:buckets] += 1
    rescue Error => e
      puts "  WARN: #{e.message}"
      tally[:failed] += 1
    end

    puts "Summary: #{dry_run ? "would delete" : "deleted"} #{tally[:tokens]} token(s) and #{tally[:buckets]} bucket(s), failed #{tally[:failed]}"
    exit 1 if tally[:failed] > 0
  end
end

GithubCacheCleanup.main if $PROGRAM_NAME == __FILE__
