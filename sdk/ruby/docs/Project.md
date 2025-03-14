# Ubicloud::Project

## Properties

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **credit** | **Float** | Remaining credit of the project in $ |  |
| **discount** | **Integer** | Discount of the project as percentage |  |
| **id** | **String** |  |  |
| **name** | **String** | Name of the project |  |

## Example

```ruby
require 'ubicloud-sdk'

instance = Ubicloud::Project.new(
  credit: 25.4,
  discount: 10,
  id: pjkkmx0f2vke4h36nk9cm8v8q0,
  name: my-project
)
```

