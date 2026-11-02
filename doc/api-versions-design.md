# API versions, deprecated names and norms: design

This document designs what the API needs where the terraform generator's spec changes
(`doc/terraform-generator-design.md` §5) rename request fields that existing clients send: aliases
for the old names; deprecation warnings and, later, the refusal of a share of the requests that use
them, with a message saying what to send instead; and an API version, chosen by the Accept header,
that accepts only the new names. Their larger purpose is to keep the API in line with its norms, so
the document also designs a check of the norms that every later change to the API must pass. The
decision is recorded in `doc/terraform-generator-brief.md`, under "Renamed request fields keep
aliases until a new API version".

## Summary

- `Accept: application/vnd.ubicloud+json; version=2` asks for version 2, as in pliny. Any other
  Accept header, or none, gets version 1, which accepts what the API accepts today. A request that
  names the vendor type without a valid version gets 400, and one that names an unknown version
  406. Responses keep `Content-Type: application/json` and gain `Vary: accept`.
- `openapi/openapi.yml` stays one document. `info.x-api-version: 2` names the latest version.
  `x-deprecated` on an operation or a request property gives the date the name was deprecated,
  what replaces it, and `removed-in`, the first version that refuses it. Version N accepts the
  whole document except what is removed in N or earlier. Responses are the same in every
  version, so a deprecated response property carries `x-deprecated` without `removed-in`. If
  version 1 is to keep a value that version 2 refuses (§11, question 1), `x-deprecated-values`
  would mark the values of a request property in the same way.
- Committee validates every request against the one schema, as today. Then `check_deprecations`,
  called once in the route block, refuses what the request's version removed (400, or 410 for an
  operation). It logs any other deprecated name with the project, warns of it in the response's
  headers, and refuses the configured share of such requests: the brownout. It also gives a renamed
  input its new name, so that routes read only new names.
- The brownout share is set for each version that removes names, as in
  `API_DEPRECATION_BROWNOUT=2:0.05`, and every share is 0 by default. A refused request gets 400
  with type `Deprecated` and a message saying what to send instead. The warning headers are RFC
  9745's `Deprecation` and a `Warning: 299` carrying the message.
- The CLI's requests ask for the latest version, so the CLI's specs prove that it sends no removed
  name, and no brownout can reach a CLI user or the web UI's CLI page.
- `openapi/norms.rb` checks the norms over the whole API in the main suite: one name per value
  (`echo`, `direction`), `readOnly` and `writeOnly`, request and response agreeing on values,
  descriptions, examples, `x-lifecycle` and `x-immutable`, and well-formed deprecations. The places
  that break a norm today are listed in `openapi/norms-known.txt`, which may only shrink, so no
  later change can add one. The terraform generator runs the same file over each type's
  operations, with no exceptions.

## 1. The Accept header

### 1.1 The grammar

The grammar is pliny's (`lib/pliny/middleware/versioning.rb` in pliny 2.0.0) and Heroku's,
narrowed to one spelling:

```
Accept: application/vnd.ubicloud+json; version=2
```

| Accept | Answer |
|---|---|
| absent, empty, `application/json`, `text/plain`, `*/*`, or anything without the vendor type | version 1 |
| `application/vnd.ubicloud+json; version=1` | version 1 |
| `application/vnd.ubicloud+json; version=2`, in any case, with `version="2"`, with `q` or other parameters, empty parameters (`;;version=2`), or after other media ranges | version 2 |
| the vendor type with no version, or with `version=two`, `version=02`, `version=0`, `version=2.0` | 400 `InvalidRequest`: "Accept names application/vnd.ubicloud+json without a valid version; send application/vnd.ubicloud+json; version=2" |
| `application/vnd.ubicloud+json; version=3` | 406 `NotAcceptable`: "API version 3 does not exist; the versions are 1, 2" |

The first media range of the vendor type decides, as in pliny. `q` is ignored, `q=0` included; no
client sends the vendor type to refuse it. Pliny also matches `application/vnd.<app>` and
`application/*+json`; clover matches only the full vendor type, which is the one Heroku documents
and the one the generated provider sends.

Pliny answers 400 for the vendor type without a version, and passes any version to the application.
Clover keeps the 400 for a missing or malformed version, which is a malformed request, and answers
406 for a well-formed version it does not serve, which is the failure RFC 9110 defines 406 for.

Version 1 stays the default for good. The Heroku design guide advises against default versions
because a default can never change, and that is the reason to keep this one fixed: a client that
sends no header keeps getting what it got, with warnings, and new clients ask for what they want.

### 1.2 The response

The response's `Content-Type` stays `application/json` in every version, as pliny arranges by
rewriting the Accept header for the application. It has to: committee chooses the response schema
by media type, and every response in the spec is keyed by `application/json`. With the vendor type
as `Content-Type`, committee's strict validation refuses every response.

Every response from the route block's API branch gains `Vary: accept`, appended to any `Vary` value
already set, because the same request can now draw different answers (RFC 9110 §12.5.5). Shared
caches do not store responses to requests that carry `Authorization`, so it matters little in
practice, but it is correct and costs one line. The public `ips-v4` list and the `/cli` route never
read the version and do not get the header.

### 1.3 Reading the version

`api_version` reads the header once and memoizes the version as an Integer. It is safe in helpers
that the web shares with the API, since a browser's Accept header gives 1. No route reads it yet:
`check_deprecations` does everything that differs by version. A route would read it only for a
difference the spec cannot state, and one schema cannot state a response that differs by version
(§3.4).

```ruby
API_MEDIA_TYPE = "application/vnd.ubicloud+json"

# Version 1, the default, up to the latest version, which the spec names.
API_VERSIONS = (1..OPENAPI.raw_schema.dig("info", "x-api-version")).to_a.freeze

# The version a request asks for, in the pliny manner: Accept names the media type
# application/vnd.ubicloud+json with a version parameter. Without that media type, the
# request gets version 1.
def api_version
  @api_version ||= if (range = env["HTTP_ACCEPT"]&.split(",")&.find { it.match?(%r{\A\s*application/vnd\.ubicloud\+json\s*(;|\z)}i) })
    unless (version = range[/;\s*version="?([1-9]\d{0,3})"?\s*(;|\z)/i, 1]&.to_i)
      fail CloverError.new(400, "InvalidRequest", "Accept names #{API_MEDIA_TYPE} without a valid version; send #{API_MEDIA_TYPE}; version=#{API_VERSIONS.last}")
    end
    fail CloverError.new(406, "NotAcceptable", "API version #{version} does not exist; the versions are #{API_VERSIONS.join(", ")}") unless API_VERSIONS.include?(version)
    version
  else
    1
  end
end
```

The route block asks for the version after committee has found the operation and before it reads
the body, so a bad header fails cheaply, and its 400 or 406 carries `Vary` too:

```ruby
@schema_validator = SCHEMA_ROUTER.build_schema_validator(r)
if (operation = @schema_validator.operation_object)
  env["clover.api_operation"] = operation.original_path
end
api_version
@schema_validator.request_validate(r)
```

The parser is a regular expression rather than `Rack::MediaType`, which raises `NoMethodError` on an
empty parameter and so would answer 500. Over 39 headers, malformed ones among them, it raised
nothing but `CloverError`. A header string tagged UTF-8 with an invalid byte would raise in
`match?`; Puma never produces one, since it hands header values over as binary strings, but a
rack-test spec could.

## 2. How the spec states the versions

### 2.1 One document

`openapi/openapi.yml` stays the only document. It describes every version at once: version 1
accepts all of it, and each later version accepts all of it except what is marked removed in that
version or an earlier one. An addition needs no mark, since a new property, value or operation
reaches every version, as additions do today, and a client ignores what it does not know. So
versions differ only by what they refuse, and only that is marked.

A document per version would copy 165 KB per version, let an addition reach one version and miss
another, and need every lint and annotation done twice; the differences would live in a diff of two
files rather than in a mark on the line they concern.

```yaml
info:
  version: 0.1.0
  x-api-version: 2

# A renamed request property (C16)
enable_ip4:
  description: Deprecated; send ip4_enabled.
  type: boolean
  deprecated: true
  x-deprecated:
    since: 2026-11-16
    removed-in: 2
    renamed-to: ip4_enabled

# An ignored request property (C2)
firewall_id:
  description: Deprecated and ignored; the rule is added to the firewall in the path.
  type: string
  deprecated: true
  x-deprecated:
    since: 2026-11-02
    removed-in: 2

# Values of a request property (C30), if version 1 keeps them (§11, question 1)
size:
  description: Requested size for the underlying VM
  type: string
  x-deprecated-values:
    burstable-1:
      since: 2026-11-16
      removed-in: 2
      renamed-to: hobby-1

# An operation
x-deprecated:
  since: 2026-02-19
  removed-in: 2
  use:
    - promoteReadReplicaPostgresDatabase

# A response property, which stays in every version (C31)
display_state:
  deprecated: true
  x-deprecated:
    since: 2026-11-16
    use:
      - state
```

| Key | Meaning |
|---|---|
| `since` | the date the name was deprecated; required; the `Deprecation` header carries it |
| `removed-in` | the first version that refuses the name, an integer above 1; required on an operation, a request property and a value; absent on a response property |
| `renamed-to` | on a request property, a sibling property that takes the same value, or in `x-deprecated-values`, the value that replaces this one; the server maps the old name to the new one |
| `use` | what to use instead when the server maps nothing: sibling properties, or operationIds for an operation |

A request property with neither `renamed-to` nor `use` is an ignored input, such as C2's three and
`flavor`, and the messages say "omit it". `deprecated: true` stays beside `x-deprecated`, since
documentation tools and the generator read it. `removed-in` may name a version that does not exist
yet: `removed-in: 3` states that a later version will refuse the name, while versions 1 and 2
accept it with warnings. That is how a name deprecated after version 2 ships keeps version 2's
clients working (§9.3); a rule that version 2 refuses every deprecated input would break them.

`since` is a date and not a version, because RFC 9745's `Deprecation` header is a date. It is the
date of the commit that deprecates the name: `flavor` on 8 Oct 2026, `promotePostgresDatabase` on
19 Feb 2026, and C2's fields on 2 Nov 2026. The 16 Nov 2026 in the examples is a placeholder.

`openapi/README.md` defines the three extensions, beside `x-lifecycle` and `x-immutable`, and says
how to deprecate a name. `info.description` gains a paragraph for readers of the published
reference: how to ask for version 2, and that it refuses what is marked removed in version 2.

### 2.2 One committee schema

Committee does not change. `OPENAPI`, `SCHEMA` and `SCHEMA_ROUTER` stay as they are: every request
in either version is validated against the whole document, so version 1's old names pass, and every
response is validated against it in every version, since responses do not differ.

The deprecations are read at load from `OPENAPI`, the object clover already holds. openapi_parser
keeps vendor extensions in `raw_schema`, dates included, so the metadata costs no second parse:

```ruby
# A deprecated operation (name is nil) or request body property, as
# described by its x-deprecated mark in the spec. rename is the new name of
# a property that was simply renamed.
Deprecation = Data.define(:operation, :name, :rename, :use, :since, :removed_in) do
  def self.from(operation, name, x)
    rename = x["renamed-to"]
    new(operation, name, rename, (rename ? [rename] : x.fetch("use", [])).freeze, x.fetch("since"), x.fetch("removed-in"))
  end

  def used?(body) = !name || body.key?(name)

  def key = [operation, name].compact.join(".")

  def subject = name || operation
end

# The deprecations of each operation, by operationId.
DEPRECATIONS = OPENAPI.paths.path.each_value.flat_map { |item| [item.get, item.post, item.patch, item.put, item.delete].compact }.to_h { |op|
  id = op.operation_id
  properties = op.request_body ? op.request_body.content["application/json"].schema.properties || {} : {}
  marked = properties.filter_map do |name, schema|
    Deprecation.from(id, name, schema.raw_schema["x-deprecated"]) if schema.raw_schema["x-deprecated"]
  end
  marked.unshift(Deprecation.from(id, nil, op.raw_schema["x-deprecated"])) if op.raw_schema["x-deprecated"]
  [id, marked.freeze]
}.reject { |_, marked| marked.empty? }.freeze
```

If version 1 is to keep a deprecated value (§11, question 1), `x-deprecated-values` would give
`Deprecation` a `value` member for `used?` to compare, and each marked value of a property would
be added to the table.

Because the parsed objects resolve `$ref`, a request body defined in `components` is covered too. An
operation's or a request property's `x-deprecated` without `since` or `removed-in` stops clover from
booting, so every spec fails on it before the norms name it. The table is built in about half a
millisecond.

A committee router per version, each over a view of the document, would cost about 55 ms of boot and
1.7 MB of retained heap per version. Only responses that differ by version would need it, and
nothing asked for so far needs those. If a response ever has to differ by version, the views can be
added then, under the same metadata.

### 2.3 The linters

`rake linter:openapi` runs on the document as today. Redocly validates it, and Spectral reports
nothing, with the extensions and their dates in place. openapi-format leaves the property extensions
where they are; on an operation it moves `tags` above `x-deprecated`, its canonical order, so a
commit that marks an operation runs the linter and keeps what it writes. Spectral refuses an integer
mapping key, which is why `removed-in` is a value and not a key.

### 2.4 What the generator sees

The generator's rule `attribute_set` leaves deprecated properties out, so it derives version 2's
request shapes from the one document, and it never derives a deprecated name, whatever its
`removed-in`. The generated provider asks for version 2 (§6), so the harness proves against the API
in process that it sends nothing version 2 refuses. The generator loads the spec with Psych, which
must permit `Date` beside `Time`, since `since` holds dates.

## 3. Aliases

### 3.1 In one place

`check_deprecations` is called once, in the API branch of the route block, after committee has
validated the request and before the route builds `typecast_params`:

```ruby
    rescue JSON::ParserError => e
      raise Committee::InvalidRequest.new("Request body wasn't valid JSON.", original_error: e)
    end

    check_deprecations(operation)
  end
```

```ruby
# Runs once committee has validated the request against the spec, which still lists every
# deprecated name. A version refuses the names it removed. Any other deprecated name is
# logged and warned of in the response's headers, the brownout refuses a share of the
# requests that use one, and a renamed input reaches the route under its new name.
def check_deprecations(operation)
  return unless (deprecations = DEPRECATIONS[operation.request_operation.operation_object.operation_id])
  return if (used = deprecations.select { it.used?(request.POST) }).empty?

  refuse_removed(used)
  @deprecations_used = used
  brownout(used, operation.path_params["project_id"])
  used.select(&:rename).each { rename_input(request.POST, it) }
end

def refuse_removed(used)
  if (gone = used.find { !it.name && it.removed_in <= api_version })
    fail CloverError.new(410, "Gone", removal_message(gone))
  end
  return if (removed = used.select { it.removed_in <= api_version }).empty?

  details = removed.to_h { [it.name, removal_message(it)] }
  fail CloverError.new(400, "InvalidRequest", details.values.join("; "), details)
end

def rename_input(body, d)
  if body.key?(d.rename)
    fail CloverError.new(400, "InvalidRequest", "#{d.name} and #{d.rename} name one value; send only #{d.rename}", {d.name => "send only #{d.rename}"})
  end
  body[d.rename] = body.delete(d.name)
end
```

The rename works on `request.POST`, the Hash that Roda's `json_parser` keeps in
`env["roda.json_params"]`. `typecast_params` is built from it the first time a route calls it,
after this hook, so a helper that reads only `ip4_enabled` sees the value that a version 1 client
sent as `enable_ip4`. Committee parsed the body separately, before this, so nothing it checked
changes afterwards. A request that sends both names is refused, since the server cannot know which
value the client meant. An operation with no deprecations costs one Hash lookup.

The rename branch arrives with its first user, C16, so that no commit carries a branch that nothing
reaches. The value branch waits for the answer to §11's question 1: C30 as approved refuses the
legacy sizes in every version, so nothing would reach it yet.

### 3.2 How version 2 refuses an old name

Version 2 refuses each name whose `removed-in` is 2 or less, with 400 `InvalidRequest` and `details`
keyed by the name, as committee's field errors are, so the CLI prints them under the message and
the generated provider can attach them to the attribute:

| Request | Answer |
|---|---|
| `{"enable_ip4": true}` | 400 "enable_ip4 was removed in API version 2: use ip4_enabled instead" |
| `{"firewall_id": "fw…", "project_id": "pj…"}` | 400 "firewall_id was removed in API version 2: omit it; project_id was removed in API version 2: omit it" |
| `{"size": "burstable-1", …}`, if version 1 keeps the legacy sizes (§11, question 1) | 400 "size burstable-1 was removed in API version 2: use hobby-1 instead" |
| `POST …/promote` | 410 `Gone` "promotePostgresDatabase was removed in API version 2: use promoteReadReplicaPostgresDatabase instead" |

A removed operation answers 410 rather than 404, which would tell a client such as terraform that
the object is gone. With one schema, committee still finds the operation, so `refuse_removed`
refuses it in two lines.

Committee validates first, so a version 2 request that sends an old name with a value of the wrong
type gets committee's type error, not the refusal. Both are 400s.

### 3.3 The web UI

Web requests never call `api_version` or `check_deprecations`, which run only in the API branch.
But the web shares helpers with the API (`vm_post`, `postgres_post`, `kubernetes_cluster_post`), and
a helper reads one name, the new one. So each rename renames the web form's field too: for C16
`views/vm/create.erb`, the option in `helpers/vm.rb` and `ContentGenerator::Vm.enable_ip4`; for C22
`views/postgres/create.erb` and its option tree; for C35 `views/kubernetes-cluster/create.erb` and
`helpers/kubernetes_cluster.rb`. A helper that read `api? ? new : old` would be the per-route
special case this design avoids.

If version 1 keeps any value aliases (§11, question 1), `check_deprecations` alone would handle
them. C30 deletes the two `.gsub("burstable", "hobby")` calls in the shared code, so a crafted
web request that names a burstable size is refused by size validation, as any unknown size is; the
web form offers only the hobby sizes.

A web page loaded before the deploy that renames its field posts the old name afterwards, which the
helper no longer reads (§10).

### 3.4 Responses do not differ by version

`display_state` (C31), `latest_restore_time` (C2) and the response's `flavor` stay in the responses
of both versions, marked `deprecated` with `x-deprecated` and no `removed-in`, until a commit
deletes them from the serializer and the spec. The generator and the norms leave deprecated
properties out, and a client that ignores a property loses nothing by its presence.

Leaving them out of version 2 would need a response schema per version, since committee validates
every response in production and `flavor` is `required`, or a pruning step after validation. Nobody
asked for either (§11, question 4). The cost of not pruning is that a version 2 client which reads a
deprecated response property breaks when the property is deleted, as a version 1 client does. The
documentation marks the property deprecated, and the generated provider never reads it.

### 3.5 C29 and C30

**C30**, refusing `burstable-1` and `burstable-2`, could belong to version 2 alone, at the cost of
the value branch, a few lines: version 1 would keep rewriting the legacy sizes, now through
`x-deprecated-values`, with the warning headers, the log line and the brownout, and version 2 would
refuse them, naming the hobby size. That changes what Daniel approved, a refusal in every version,
so it is an open question (§11, question 1). Until he answers, C30 deletes the two `.gsub` calls
and every version refuses.

**C29**, the metric destination create answering the destination, cannot belong to version 2 alone
without a response that differs by version, which §3.4 leaves out. It lands in every version, as
approved. It also fixes the Ruby SDK, whose `add_metric_destination` promises the destination but
appends the whole database to `metric_destinations` today. The CLI reads the list with a GET in the
same commit, and the old provider has no metric destination resource.

## 4. Deprecation warnings and the brownout

### 4.1 The headers

A response to a request that used a deprecated name carries these headers, on success and on
refusal alike:

```
Deprecation: @1794787200
Warning: 299 - "enable_ip4 is deprecated: use ip4_enabled instead"
```

- `Deprecation` (RFC 9745) is a structured-field date, `@` and Unix seconds, taken from the earliest
  `since` among the names the request used, at midnight UTC. RFC 9745 defines the field for the
  resource the request names; using it when a name in the request is deprecated stretches that.
- `Warning: 299` carries the message, one quoted value per name. RFC 9111 made the field obsolete,
  but it is the only standard field that carries text, Kubernetes sends exactly this form for its
  deprecations, and kubectl and client-go print it. A provider generated before a later deprecation
  keeps sending the old name, and could show this text to its user as a terraform warning.
  `String#dump` makes a valid quoted string of any message.
- `Link rel="deprecation"` (RFC 9745) would point to a page explaining each name, and waits until
  the page exists (§11, question 9).
- `Sunset` (RFC 8594) waits for a date. No deprecation has one.

The headers are added in the `after` hook, because Roda's error handler resets the response before
it renders an error, and a refusal by the brownout must carry them too:

```ruby
# A response from the route block's API branch depends on the version asked for.
headers["vary"] = [headers["vary"], "accept"].compact.join(", ") if @schema_validator
add_deprecation_headers(headers) if @deprecations_used
@schema_validator ||= SCHEMA_ROUTER.build_schema_validator(request)
```

```ruby
# The error handler resets the response, so the after hook adds these, and they reach
# refusals too.
def add_deprecation_headers(headers)
  headers["deprecation"] = "@#{@deprecations_used.map { it.since.strftime("%s").to_i }.min}"
  headers["warning"] = @deprecations_used.map { "299 - #{deprecation_message(it).dump}" }.join(", ")
end

def deprecation_message(d) = "#{d.subject} is deprecated: #{replacement(d)}"

def removal_message(d) = "#{d.subject} was removed in API version #{d.removed_in}: #{replacement(d)}"

def replacement(d) = d.use.empty? ? "omit it" : "use #{d.use.join(" and ")} instead"
```

`Date#strftime("%s")` gives midnight UTC whatever the process's time zone, where `Date#to_time`
would give local midnight.

### 4.2 The wording

| When | Status, type | Message |
|---|---|---|
| version 1, a deprecated name | 200, as before | none; the headers above |
| version 1, the brownout | 400 `Deprecated` | enable_ip4 is deprecated: use ip4_enabled instead. Requests that use a deprecated name will stop working; to warn of that, 5% of them are refused now, including this one. |
| version 1, both names | 400 `InvalidRequest` | enable_ip4 and ip4_enabled name one value; send only ip4_enabled |
| version 2, removed | 400 `InvalidRequest` | enable_ip4 was removed in API version 2: use ip4_enabled instead |
| version 2, removed operation | 410 `Gone` | promotePostgresDatabase was removed in API version 2: use promoteReadReplicaPostgresDatabase instead |

The advice is in the top-level message, which every client prints, and also in `details`, keyed by
the name. The messages are built from the metadata, not from descriptions, so editing a description
does not change what the API answers.

### 4.3 The brownout

```ruby
def brownout(used, project_id)
  share = used.map { Config.api_deprecation_brownout.fetch(it.removed_in, 0.0) }.max
  refused = rand < share
  Clog.emit("deprecated api use", {deprecated_api_use: {project_id:, version: api_version, keys: used.map(&:key), refused:, user_agent: env["HTTP_USER_AGENT"].to_s[0, 200]}})
  return unless refused

  message = "#{used.map { deprecation_message(it) }.join("; ")}. Requests that use a deprecated name will stop working; " \
    "to warn of that, #{format("%g", share * 100)}% of them are refused now, including this one."
  fail CloverError.new(400, "Deprecated", message, used.select(&:name).to_h { [it.name, deprecation_message(it)] })
end
```

```ruby
# config.rb
# The brownout: for an API version, the share of requests refused for using a name that
# version removed, as version:share pairs ("2:0.05").
override :api_deprecation_brownout, "", ->(v) { v.split(",").to_h { it.split(":").then { |version, share| [Integer(version), Float(share)] } }.freeze }
```

- **Where the share is set.** `Config` reads it from `API_DEPRECATION_BROWNOUT`. The spec states
  facts about the API; the share is operational policy, changed week by week. The setting gives a
  share for each version that removes names, so the names version 2 removed can be at 50 % while the
  names a later version removes start at 0. One global share would put every name deprecated for
  version 3 under the share left from version 2 the moment `x-api-version` rose, a production change
  hidden in a spec edit. `"2:0.05,3:1"` parses to `{2 => 0.05, 3 => 1.0}`, the empty default to
  `{}`, and a malformed share stops the process at boot.
- **Which requests.** The brownout applies to a request that uses a deprecated name its version
  still accepts: in version 1, any deprecated name; in version 2, only those with `removed-in: 3`
  or later, under the share for that version.
- **One draw per request**, at the highest share among the names it used, so a request with two old
  names is refused at the configured rate and not more often.
- **The status** is 400 with type `Deprecated`, and no `Retry-After`. A 429 or a 5xx invites an
  automatic retry, and the generated provider retries anything that carries `Retry-After`; a
  refusal that a retry hides warns nobody. The type tells it apart in logs from a request that is
  wrong today. 410 would say the resource is gone, which is false.
- **Deterministic tests.** `rand` is in [0, 1), so `rand < 0.0` is never true and `rand < 1.0`
  always is. The route specs stub the setting to `{2 => 1.0}` or leave the default, which covers
  both outcomes.
- **The end of an alias.** At a share of 1 every version 1 request that uses the name is refused,
  with a message that says what to send instead, so the alias is gone in effect. Deleting the
  property from the spec afterwards is a cleanup, after which committee answers "unrecognized
  parameters" instead. Nothing raises the share on a date, since that would be a time bomb in the
  test suite.

A share above 0 is an operational step, taken after the generated provider is released.

### 4.4 Counting who still uses an old name

Every request that uses a deprecated name writes one log line, refused or not:

```json
{"deprecated_api_use": {"project_id": "pj…", "version": 1, "keys": ["createVM.enable_ip4"], "refused": false,
  "user_agent": "terraform-provider-ubicloud/0.4.1"}, "message": "deprecated api use"}
```

Grouped by `project_id` and `keys` in the log store, the lines say which customers still use which
alias, and the user agent tells the old terraform provider from the SDK and from scripts. The CLI
asks for the latest version (§6), so it never appears in these logs.

## 5. The norms

### 5.1 What is checked

`OpenapiNorms` checks the document and lists one line per violation, as `norm: place: what to do`.
Each norm is a private method named `norm_<name>`, and `violations` collects them by name, as Roda
collects its hooks, so there is no list to keep in step. The file is plain Ruby that requires only
`date` and is given the document already parsed, so the terraform generator, which does not load
clover, can require it.

| Norm | Rule |
|---|---|
| `echo` | a request body property is echoed under its name by the operation's success response, or is `writeOnly` |
| `direction` | a response property that no request body of an operation returning it carries is `readOnly` |
| `echo_agreement` | for an echoed pair, the request accepts every value the response may hold, in type, format, enum, items and map values; `nullable` may differ |
| `described` | every top-level property of a request or a success response, and every parameter, has a description |
| `examples` | every path parameter, required request property and response `id` has an example |
| `lifecycle_enum` | `x-lifecycle` lists `pending` and `failed` strings on a `readOnly` property whose enum holds them, once per response |
| `immutable_readonly` | `x-immutable` marks only `readOnly` properties |
| `deprecation` | `deprecated: true` goes with `x-deprecated`; `since` is a date; `removed-in` is above 1 where a client sends the name and absent on a response property; `use` names what exists; `renamed-to` names a live sibling of the same type; a deprecated request property is not required |

`echo` and `direction` together are "one name per value": `enable_ip4` against `ip4_enabled`, and
`cp_nodes` against `cp_node_count`, break both. An action whose body names another object, such as
a firewall's attach-subnet `private_subnet_id`, keeps `echo` by marking the property `writeOnly`,
which it is. A path parameter is not a body input, so a response property such as `Vm.location`
must be `readOnly`, which is what OpenAPI means by the keyword.

The rule that every `allOf` member has `type: object` stays with C11's Spectral rule, which covers
the whole document at lint time with the exact location; a copy in Ruby would put one rule in two
places.

### 5.2 Places

A place is named after the schema that defines it, so every line is unique and leads to one spot in
the document: `Vm.name`, `createVM.ip4_enabled` for a request body, `responses/Vms.items` for a list
response's wrapper, `responses/Vm/allOf/1.subnet` for a property of an `allOf` member,
`parameters/vm_reference`, and `createVM 200` for an inline response.

### 5.3 Where it runs, and the ratchet

A main-suite spec, `spec/openapi_norms_spec.rb`, holds one passing and one failing example for each
norm and branch, and checks the real document against `openapi/norms-known.txt`:

```ruby
it "holds for openapi.yml, but for the known violations, which may only shrink" do
  found = described_class.new(YAML.safe_load_file("openapi/openapi.yml", permitted_classes: [Date, Time])).violations.sort
  known = File.readlines("openapi/norms-known.txt", chomp: true)
  expect(found - known).to eq([]), "openapi.yml breaks these norms; keep to them:\n#{(found - known).join("\n")}"
  expect(known - found).to eq([]), "openapi.yml now keeps these norms; delete these lines from openapi/norms-known.txt:\n#{(known - found).join("\n")}"
end
```

A new violation fails the spec, and so does a fixed one still listed, so the file can only shrink.
C16, for instance, fails the spec until it deletes `direction: Vm.ip4_enabled` and
`echo: createVM.enable_ip4`, the violations it exists to fix. A change that adds an operation or a
property keeps the norms for it, or fails: C26's new GETs must come with their descriptions and
examples.

When this was designed, 333 places broke a norm: 157 `direction`, 65 `described`, 69 `examples`,
40 `echo` and 2 `echo_agreement`. Seventy are the `items`, `count` and `pagination_key` of list
responses, which need `readOnly` and a description, and one change to the spec alone clears them.
About 74 are properties in the schemas of the fourteen terraform types of the first cut, which the
generator's annotation changes clear. The rest are request bodies and parameters, of first-cut
operations and of the rest of the API, such as GitHub cache entries, machine image versions and
private locations. The check takes about 40 ms over the whole document.

The file lives in `openapi/`, beside the document it judges, and not in `lib/`, which clover
autoloads in production; as with the generator, nothing in it runs while clover serves requests.
The coverage helper already counts every Ruby file under `openapi/`, so the main suite covers the
file, at 100 % of lines and branches from its spec.

### 5.4 One rule, one place

Seven of the generator's invariants are facts about the document, not about deriving a type, and
they move:

| Invariant | Moves to |
|---|---|
| `typed_allof` | C11's Spectral rule |
| `response_direction` | `norm_direction` |
| `echo_agreement` | `norm_echo_agreement` |
| `lifecycle_enum` | `norm_lifecycle_enum` |
| `immutable_readonly` | `norm_immutable_readonly` |
| `examples` | `norm_examples` |
| `described` | `norm_described` |

The generator keeps the five that are about derivation (`doc/terraform-generator-design.md` §4.7),
and adds rule `norms`, which requires `openapi/norms.rb` by path and refuses a defined type whose
operations break any norm, with no known violations allowed:

```ruby
# The API's norms hold for every operation of a defined type.
def norms
  ids = [@create, @get, @api.paths[@item.path]["delete"]].compact.map { it["operationId"] } + @verbs.select(&:verb).map(&:id)
  violations = OpenapiNorms.new(@api.doc, only: ids).violations
  refuse @name, "breaks the API's norms:\n#{violations.join("\n")}" if violations.any?
end
```

Run over the VM type's operations after C16 alone, the norms listed 19 lines, all of them work
that the generator's design had already planned: `echo: createVM.private_subnet_id` (C15), `echo:
createVM.storage_size` (C16), `readOnly` on ten response properties, `writeOnly` on `public_key`
and `init_script`, four examples and one description (C19). With C15, C16 and C19 in place, the VM
type breaks no norm, as rule `norms` requires of every defined type.

## 6. Clients

- **The CLI.** The Go binary posts its argv to `/cli` with `Accept: text/plain`, and knows nothing
  of the API's shapes. `UbiCli` calls the API in process through the SDK's Rack adapter, which
  merges the `/cli` request's env into every inner request, so the inner requests would inherit the
  outer Accept header. One line sets the version of the CLI's requests:

  ```ruby
  def sdk
    @sdk ||= Ubicloud.new(:rack, app: Clover, env: @env.merge("HTTP_ACCEPT" => "#{Clover::API_MEDIA_TYPE}; version=#{Clover::API_VERSIONS.last}"), project_id: project_ubid)
  end
  ```

  The CLI follows the latest version, so raising `x-api-version` moves the CLI in the same commit,
  and its specs prove that it sends nothing the new version refuses. Each change updates the CLI
  where it must: the mechanism stops `pg create` sending `flavor` (its `--flavor` accepts only
  `standard`, the default); C16 makes `vm create` send `ip4_enabled`; C22 makes `pg create` send
  `target_version`; C30 maps `-s burstable-N` to `hobby-N` in `pg create` and `pg modify`, whose
  size options list the legacy names; C35 deletes `kc create`'s mapping of `cp_node_count` to
  `cp_nodes`. With the CLI on version 2, every CLI spec and golden file passed in a prototype. The
  binary needs no release.
- **The web UI's CLI page** runs `UbiCli.process` with the browser's env, so it gets version 2 too,
  and no brownout can reach it.
- **The Ruby SDK** (`sdk/ruby`) sends `accept: text/plain` from its Net::HTTP adapter, so its users
  get version 1. Its models send no deprecated name. A caller who passes one to `create` gets the
  warning headers, which the SDK does not surface, and in the brownout an `Ubicloud::Error` whose
  `params` hold the API's message naming the new field. The README's lists of create options lose
  `flavor`, `enable_ip4` and `version`.
- **The web UI** is not versioned (§3.3).
- **The old terraform provider** sends no vendor Accept header, so it gets version 1. Its
  `enable_ip4` keeps working, with headers it ignores, until the brownout; then its users see
  messages naming what to send, and move to the generated provider, since they cannot change what
  the old one sends.
- **The generated provider** sends `Accept: application/vnd.ubicloud+json; version=2` on every
  request, from `client.go`. The derivation leaves deprecated names out, and the harness proves
  against the API in process that version 2 accepts everything the provider sends. Raising the
  provider's version is a deliberate change to one constant.

## 7. Tests

`spec/routes/api/api_version_spec.rb` covers:

- the grammar: version 1 for six headers; version 2 for five spellings, the empty parameters among
  them; 400 for four malformed headers, with `Vary`; 406 for version 3; `Content-Type` and `Vary`
  on a version 2 answer; no `Vary` on `ips-v4`;
- an ignored input (`firewall_id`): accepted in version 1 with the log line and both headers;
  refused in version 2 with `details`; the brownout at `{2 => 1.0}` refusing with the message, the
  headers and no rule made; the share for another version refusing nothing; no headers on a request
  without an old name;
- a deprecated operation: version 1 answering as before with the headers, version 2 answering 410;
- the CLI's requests on the latest version, with `pg create -f standard` drawing no log line, and no
  `Vary` on the `/cli` response;
- with C16, the old name renamed, with the VM getting IPv4; both names refused; version 2 refusing;
  the new name working in both versions without headers;
- with C30, if version 1 keeps the legacy sizes, the size renamed on create and on PATCH in version
  1 and refused in version 2.

Every example that expects a `Clog.emit` first allows other calls, since subnet assembly sometimes
logs too.

`spec/openapi_norms_spec.rb` holds a passing and a failing example of each norm on inline documents,
examples of `only:`, and the ratchet over the real document. `helpers/api_version.rb` and
`openapi/norms.rb` reach 100 % of lines and branches from these two specs, in the frozen run too.

## 8. The order of changes

The mechanism (the Accept header, the deprecation table, the refusals, the headers and the
brownout, with the CLI on version 2 and the existing deprecations marked) comes first, then the
norms with their known list, and then C16, the first alias. From then on, every change that
edits `openapi/openapi.yml` runs the norms spec, and deletes from the known list the lines it fixes.
C16, C22 and C35 add `renamed-to` and rename the web field; C30 adds the value branch, if Daniel
agrees; C31 marks `display_state`; C36 follows his answer. The generator's loader permits `Date`,
and the engine sends the vendor Accept header, which is harmless before the API reads it. The
generator's seven document invariants give way to rule `norms` once both exist. A brownout share
above 0 waits for the generated provider's release.

## 9. Worked examples

### 9.1 C16: VM create's `enable_ip4` becomes `ip4_enabled`

The spec gains `ip4_enabled` and marks the old name (§2.1). `helpers/vm.rb` reads only the new
name:

```ruby
assemble_params = typecast_params.convert!(symbolize: true) do |tp|
  tp.nonempty_str(["size", "unix_user", "boot_image", "private_subnet_id", "gpu", "init_script"])
  tp.pos_int("storage_size")
  tp.bool("ip4_enabled")
end
assemble_params[:enable_ip4] = assemble_params.delete(:ip4_enabled)
assemble_params.compact!
```

```
POST /project/pj…/location/eu-central-h1/vm/web          Accept: application/json
{"public_key": "ssh-ed25519 AAAA…", "enable_ip4": true}

200   Content-Type: application/json   Vary: accept
      Deprecation: @1794787200
      Warning: 299 - "enable_ip4 is deprecated: use ip4_enabled instead"
{"id": "vm…", "ip4_enabled": true, …}
```

At `API_DEPRECATION_BROWNOUT=2:0.05`, one such request in twenty:

```
400   Deprecation: @1794787200   Warning: 299 - "enable_ip4 is deprecated: use ip4_enabled instead"
{"error": {"code": 400, "type": "Deprecated",
  "message": "enable_ip4 is deprecated: use ip4_enabled instead. Requests that use a deprecated name will stop working; to warn of that, 5% of them are refused now, including this one.",
  "details": {"enable_ip4": "enable_ip4 is deprecated: use ip4_enabled instead"}}}
```

Version 2:

```
POST …/vm/web     Accept: application/vnd.ubicloud+json; version=2
{"public_key": "…", "enable_ip4": true}
400 {"error": {"code": 400, "type": "InvalidRequest", "message": "enable_ip4 was removed in API version 2: use ip4_enabled instead",
     "details": {"enable_ip4": "enable_ip4 was removed in API version 2: use ip4_enabled instead"}}}

{"public_key": "…", "ip4_enabled": true}
200 {"id": "vm…", "ip4_enabled": true, …}
```

`gpu`, which C16 replaces by `gpu_count` and `gpu_device`, is not a rename, since one string becomes
two fields: it gets `use: [gpu_count, gpu_device]`, version 1 passes it to the route as today, and
version 2 refuses it.

### 9.2 C30: the burstable sizes, if version 1 keeps them

`x-deprecated-values` on `size`, in both postgres create and PATCH (§2.1), and the routes lose their
rewrite:

```ruby
size = typecast_params.nonempty_str!("size")                     # was .gsub("burstable", "hobby")
size = typecast_params.nonempty_str("size", pg.target_vm_size)   # was .gsub("burstable", "hobby")
```

In version 1, `{"size": "burstable-1", "storage_size": 64}` makes a `hobby-1` database, with
`Warning: 299 - "size burstable-1 is deprecated: use hobby-1 instead"`; in version 2 it gets 400
"size burstable-1 was removed in API version 2: use hobby-1 instead". The `gsub` also turned strings
such as `burstable-4` into the unknown `hobby-4`, which was refused; now it is refused as
`burstable-4`.

### 9.3 A name deprecated after version 2 ships

Suppose a later change replaces `maintenance_window_start_at`. It is marked `x-deprecated: {since:
…, removed-in: 3, use: [...]}`, and `x-api-version` stays 2. Versions 1 and 2 both accept it, warn
of it and log it; the brownout share for 3 is 0 until someone sets it. The generator leaves it out
from then on, so a regenerated provider no longer sends it. When `x-api-version` becomes 3, the
commit that raises it moves the CLI to version 3 too, and the CLI's specs fail on every name it
still sends that version 3 refuses. Nothing in that sequence breaks a version 2 client, and the
norms refuse the deprecation if it lacks `removed-in`.

### 9.4 C36 under the default answer

C36 lets a cluster be made without a default nodepool, and deprecates `worker_size` and
`worker_nodes` with `x-deprecated: {since: …, removed-in: 3, use: [createKubernetesNodepool]}`.
They are not second names for a value the response carries under another name; they are a
convenience that makes a default nodepool. Version 2 keeps accepting them, with warnings, so
`ubi kc create -z … -w …` keeps working on version 2 with no CLI change, and the generated
provider, which leaves deprecated names out, derives a cluster without worker inputs, as the GKE
pattern Daniel chose requires.

## 10. Limits and risks

1. **Renaming a required property.** One schema cannot require the new name while version 1 may
   still send the old one, so neither would be required, and the generator would see the input as
   optional. None of the generator's renames is of a required property; `worker_size`, which is
   required today, stops being required with C36. A rename of a required property would need a
   schema per version.
2. **Only top-level body properties and operations.** A deprecated query parameter, or a property
   nested in an object, is not handled, and the norms do not yet refuse `x-deprecated` placed
   there. None exists.
3. **Responses are the same in every version** (§3.4), so a version 2 client can come to depend on
   a deprecated response property.
4. **The stale web form.** For one deploy, a create page loaded before a rename posts the old field
   name, which the shared helper no longer reads: a VM without IPv4 (C16), a database at the
   default version (C22), a cluster with one control plane node (C35). The page shows the result at
   once. If the renames ship in one deploy, the window is the create pages open across it.
5. **The brownout fails real requests, by design.** It must wait for the new provider's release;
   the CLI is safe from the start. Users of the old provider cannot change what it sends.
6. **The rename edits the parsed body.** Anything that read the raw body after the hook would see
   the old name; nothing in the API does, and the CLI's Rack adapter resets `roda.json_params` for
   each request.
7. **`Deprecation` on an input** follows practice more than RFC 9745's letter, and `Warning` is
   obsolete, so a strict reader of either RFC will object.
8. **The known list couples spec changes to the norms.** Each spec change must delete the lines it
   fixes, and the failure says which; a change that adds an operation must meet the norms for it.
9. **Log volume.** One line per request that uses a deprecated name. If the old provider is busy,
   the line can be sampled later.

## 11. Open questions

Each has a recommendation, and a default that holds until Daniel Farina answers, so that no change
waits on an answer.

1. **May version 1 keep rewriting the burstable sizes?** C30 was approved as a refusal in every
   version. With versions, the rewrite can become a deprecated value in version 1, warned of,
   logged and subject to the brownout, while version 2 refuses it. It costs a few lines, and spares
   the old provider's users and scripts a break before anything has warned them; terraform's
   "inconsistent result after apply", the reason for C30, concerns only the generated provider,
   which asks for version 2. Recommendation: yes. **Default:** C30 as approved; every version
   refuses, and the CLI still maps the legacy sizes.
2. **Does C29 land in every version, as approved?** Version 2 alone could carry it only with a
   response that differs by version (§2.2). Recommendation and **default:** every version.
3. **Which way for C36's `worker_size` and `worker_nodes`?** (a) `removed-in: 3`, as §9.4 shows,
   with no CLI change; (b) `removed-in: 2`, with `ubi kc create` making the cluster alone and saying
   how to add a nodepool once it is ready; (c) not deprecated, write-only inputs that make a default
   nodepool, as GKE's `initial_node_count` does, which brings them back into the generated provider;
   (d) `removed-in: 2`, with the CLI's `kc create` alone staying on version 1, where it meets the
   brownout. Recommendation and **default:** (a); moving to (b) later means changing one number and
   the CLI.
4. **Should version 2 leave deprecated response properties out?** A pruning step after validation
   would cost about 30 lines and fail safe. Recommendation and **default:** keep them in every
   version; prune only if a version 2 client is found to depend on one.
5. **May version 2 be offered before the known violations are fixed?** The generator refuses any
   type whose operations break a norm, so the generated provider's types have none; the rest is
   written debt that can only shrink. Recommendation and **default:** announce version 2 with the
   generated provider's release.
6. **Which status for a missing, a malformed and an unknown version?** Recommendation and
   **default:** 400 for a missing or malformed version, 406 for an unknown one (§1.1).
7. **Does version 1 stay the default for good?** Once every version 1 alias is browned out at a
   share of 1, version 1 accepts what version 2 accepts, so there is little left to retire.
   Recommendation and **default:** yes.
8. **The brownout's schedule, its end, and per-project exemptions.** Recommendation: start after
   the provider's release; ramp by hand, for instance 1 %, 10 %, 50 % and 100 % over some weeks,
   watching the log lines by project; end at a share of 1 and leave deletion for later; no automatic
   sunset; and a project feature flag holding a share that replaces the configured one, 0 to exempt
   a customer mid-migration and 1 to let a customer test that nothing still uses an old name, at
   one primary-key query on requests that use a deprecated name. **Default:** the share stays 0,
   and no flag is built.
9. **Which warning headers, and where does the deprecation page live?** Recommendation: send
   `Deprecation` and `Warning`; add `Link rel="deprecation"` once a page exists, at
   `https://www.ubicloud.com/docs/api/versions` with one anchor per name (`createVM.enable_ip4`),
   generated from the spec. To follow the RFCs strictly instead, drop `Warning` and let the page
   carry the text. **Default:** `Deprecation` and `Warning`, and no `Link`.

## 12. Evidence

A prototype of the mechanism and the norms, with small cuts of C16 and C30, ran against clover with
the terraform rebuild's first spec changes. In that prototype:

- the route and norms specs passed, frozen and unfrozen, with both new files at 100 % of lines and
  branches, and about 1,200 examples of the API, web, CLI, SDK and config specs passed unchanged,
  every CLI golden file among them, with the CLI on version 2;
- the Accept parser raised nothing but `CloverError` over 39 headers, and took under 2 µs a call;
- the deprecation table was built from `OPENAPI` in about half a millisecond, `x-deprecated` read
  with its date;
- Redocly and Spectral passed the spec with the marks in place;
- the norms ran in 36 to 54 ms with no gem loaded, named every violation at a distinct place, and
  over the VM type's operations listed only changes the generator's design already plans;
- the ratchet failed after C16's cut until the two lines C16 fixes were deleted;
- a rename in `request.POST` reached `typecast_params`, and the VM got IPv4;
- headers set before an error were lost, and the after hook's reached refusals;
- a vendor `Content-Type` on responses made committee refuse every response;
- `API_DEPRECATION_BROWNOUT` parsed as §4.3 says, and a malformed share stopped the process at
  boot.

The prototype did not include the generator's `norms` method, the engine's Accept header, or C36
with `removed-in: 3`.
