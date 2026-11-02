# The OpenAPI spec

`openapi.yml` describes clover's API. Committee validates every API request and response against
it. `rake linter:openapi` checks the spec and rewrites it in canonical order; commit what the
linter leaves.

## API versions

A request selects a version of the API with the header
`Accept: application/vnd.ubicloud+json; version=N`. A request that does not name that media type
gets version 1. One that names the media type without a well-formed version is refused with 400,
and one that names a version that does not exist, with 406. Responses always have
`Content-Type: application/json`.

This one document describes every version. Version N accepts all of it except what is marked as
removed in version N or earlier, so an addition needs no mark: a new operation, property or value
reaches every version. Responses are the same in every version.

## Extensions

### `x-api-version`

This goes in `info`, and gives the latest API version as an integer. The CLI asks for that
version.

### `x-deprecated`

This goes on an operation, or on a top-level property of a request body or response schema, next
to `deprecated: true` (which documentation tools read):

```yaml
firewall_id:
  description: Deprecated and ignored; the rule is added to the firewall in the path.
  type: string
  deprecated: true
  x-deprecated:
    since: 2026-11-02
    removed-in: 2
```

| Key | Meaning |
|---|---|
| `since` | the date the name was deprecated, unquoted so that it loads as a date; the `Deprecation` header carries it |
| `removed-in` | the first version that refuses the name, above 1; required on an operation or request property, and absent on a response property |
| `use` | a list of what to use instead: sibling properties, or operationIds for an operation; if it is absent, clients are told to omit the name |
| `renamed-to` | on a request property only, in place of `use`: the sibling property that now takes its value |

Versions before `removed-in` accept the name. The server logs each request that uses a deprecated
name ("deprecated api use", with the project, the version and the user agent), and the response
carries a `Deprecation` header giving the earliest `since` among the names used, and a
`Warning: 299` header saying what to use instead. From `removed-in` on, the server refuses a
property with 400 and `details` keyed by its name, and an operation with 410.

Before `removed-in`, the server passes the value of a property with `renamed-to` to the route
under its new name, so that the route need read only that name. A request that sends both names
is refused with 400.

`API_DEPRECATION_BROWNOUT` makes versions before `removed-in` refuse a share of the requests that
use the name, with 400 and type `Deprecated`. It takes comma-separated version:share pairs: `2:0.05`
refuses one in twenty of the requests that use a name removed in version 2. By default nothing is
refused.

The server looks only at operations and top-level request body properties; a deprecated query
parameter or nested property is neither warned of nor refused.

## Deprecating a name

1. Mark it `deprecated: true` and give it `x-deprecated` with `since`, the date of the commit, and,
   for a request property or an operation, `removed-in`. A version that clients already use must
   not start refusing a name, so `removed-in` must name a version not yet announced, which may be
   above `x-api-version`.
2. Say in its description that it is deprecated, and what to send instead.
3. If `removed-in` is not above `x-api-version`, the CLI asks for a version that refuses the name,
   so stop the CLI from sending it in the same commit.
4. A deprecated response property stays in the responses of every version until a commit deletes
   it from the serializer and the spec.
5. Run `rake linter:openapi`.
