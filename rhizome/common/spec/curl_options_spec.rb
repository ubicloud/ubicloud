# frozen_string_literal: true

require "pathname"

# A token stops carrying curl's options at the first pipe, redirect or command
# separator: "openssl dgst -sha256" downstream of a tee is not curl's argv.
CURL_ARGV_TERMINATORS = ["|", ">", "<", ";", "&&", "||", "&"].freeze
CURL_BUNDLED_SHORT_OPTION = /\A-[A-Za-z][A-Za-z0-9]*\z/

# Quoting, commas, brackets and the backslashes of a shell-escaped expectation
# string are stripped first, so a Ruby argv array, a spec expectation and a
# shell line all tokenize the same way.
def curl_bundled_digits(line)
  tokens = line.delete("\\\"'`,[]()").split
  start = tokens.index("curl")
  return [] if start.nil?

  rest = tokens[(start + 1)..]
  stop = rest.index { CURL_ARGV_TERMINATORS.include?(_1) }
  rest = rest[0...stop] if stop
  rest.select { CURL_BUNDLED_SHORT_OPTION.match?(_1) && _1.match?(/[0-9]/) }
end

# curl bundles short options, so a digit written against a letter is not an
# argument to it: "-L3" is --location --sslv3 and "-L10" is --location --tlsv1
# --http1.0, by curl's own option table ("-3, --sslv3", "-1, --tlsv1",
# "-0, --http1.0"). Both were written here as if they set a redirect limit, and
# neither had anything to do with redirects -- one asked for a protocol RFC
# 7568 withdrew and the other forced HTTP/1.0 on a multi-gigabyte image fetch.
# The mistake is invisible when read quickly, which is why it survived in six
# places across this tree, so it is checked here rather than remembered. A
# count of redirects is spelled --max-redirs N; anything else digit-bearing is
# a bundle nobody asked for.
#
# rubocop:disable RSpec/DescribeClass
RSpec.describe "curl invocations" do
  # rubocop:enable RSpec/DescribeClass
  rhizome_root = Pathname.new(File.expand_path("../..", __dir__))
  # This file is the checker; the deliberately wrong argv in its own examples
  # below is a fixture, not an invocation, so it is the one file left unread.
  files = rhizome_root.glob("**/*").select { _1.file? && !_1.to_s.include?("/.") && _1.to_s != __FILE__ }

  it "reads the whole rhizome tree" do
    expect(files.length).to be > 50
  end

  it "spells every curl option in a form that is not a bundled digit" do
    found = files.flat_map { |path|
      path.read(encoding: "UTF-8").lines.each_with_index.filter_map { |line, index|
        next if line.lstrip.start_with?("#")

        offenses = curl_bundled_digits(line)
        next if offenses.empty?

        "#{path.relative_path_from(rhizome_root)}:#{index + 1}: #{offenses.join(" ")}"
      }
    }

    expect(found).to eq([])
  end

  it "recognises a bundled digit and leaves a separated argument alone" do
    expect(curl_bundled_digits(%(curl -f -L3 https://example.com/x))).to eq(["-L3"])
    expect(curl_bundled_digits(%(curl -f -L10 https://example.com/x))).to eq(["-L10"])
    expect(curl_bundled_digits(%(r "curl", "-L3", "-o", path, url))).to eq(["-L3"])
    expect(curl_bundled_digits(%(curl --fail --location --max-redirs 3 https://example.com/x))).to eq([])
    expect(curl_bundled_digits(%(curl -f -sS -L --max-time 60 -r 0-0 -D - -o /dev/null url))).to eq([])
    expect(curl_bundled_digits(%(curl --fail --location url | tee >(openssl dgst -sha256) > path))).to eq([])
    expect(curl_bundled_digits(%(tar -xzf /tmp/spdk.tar.gz --strip-components=1))).to eq([])
  end
end
