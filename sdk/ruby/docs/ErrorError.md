# Ubicloud::ErrorError

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **code** | **Integer** |  |  |
| **message** | **String** |  |  |
| **type** | **String** |  |  |
| **details** | **Object** |  | [optional] |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::ErrorError.new(
  code: 401,
  message: There was an error logging in,
  type: InvalidCredentials,
  details: null
)
```

