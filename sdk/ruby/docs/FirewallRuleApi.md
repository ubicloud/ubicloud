# Ubicloud::FirewallRuleApi

All URIs are relative to *https://api.ubicloud.com*

| Method | HTTP request | Description |
| ------ | ------------ | ----------- |
| [**create_firewall_rule**](FirewallRuleApi.md#create_firewall_rule) | **POST** /project/{project_id}/firewall/{firewall_name}/firewall-rule | Create a new firewall rule |
| [**create_location_firewall_firewall_rule**](FirewallRuleApi.md#create_location_firewall_firewall_rule) | **POST** /project/{project_id}/location/{location}/firewall/{firewall_name}/firewall-rule/{firewall_rule_id} | Create a new firewall rule |
| [**create_location_firewall_rule**](FirewallRuleApi.md#create_location_firewall_rule) | **POST** /project/{project_id}/location/{location}/firewall/{firewall_name}/firewall-rule | Create a new firewall rule |
| [**delete_firewall_rule**](FirewallRuleApi.md#delete_firewall_rule) | **DELETE** /project/{project_id}/firewall/{firewall_name}/firewall-rule/{firewall_rule_id} | Delete a specific firewall rule |
| [**delete_location_firewall_firewall_rule**](FirewallRuleApi.md#delete_location_firewall_firewall_rule) | **DELETE** /project/{project_id}/location/{location}/firewall/{firewall_name}/firewall-rule/{firewall_rule_id} | Delete a specific firewall rule |
| [**delete_location_postgres_firewall_rule**](FirewallRuleApi.md#delete_location_postgres_firewall_rule) | **DELETE** /project/{project_id}/location/{location}/postgres/{postgres_database_name}/firewall-rule/{firewall_rule_id} | Delete a specific firewall rule |
| [**get_firewall_rule_details**](FirewallRuleApi.md#get_firewall_rule_details) | **GET** /project/{project_id}/firewall/{firewall_name}/firewall-rule/{firewall_rule_id} | Get details of a firewall rule |
| [**get_location_firewall_firewall_rule_details**](FirewallRuleApi.md#get_location_firewall_firewall_rule_details) | **GET** /project/{project_id}/location/{location}/firewall/{firewall_name}/firewall-rule/{firewall_rule_id} | Get details of a firewall rule |


## create_firewall_rule

> <FirewallRule> create_firewall_rule(project_id, firewall_name, create_firewall_rule_request)

Create a new firewall rule

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallRuleApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall
create_firewall_rule_request = Ubicloud::CreateFirewallRuleRequest.new({cidr: 'cidr_example'}) # CreateFirewallRuleRequest | 

begin
  # Create a new firewall rule
  result = api_instance.create_firewall_rule(project_id, firewall_name, create_firewall_rule_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->create_firewall_rule: #{e}"
end
```

#### Using the create_firewall_rule_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<FirewallRule>, Integer, Hash)> create_firewall_rule_with_http_info(project_id, firewall_name, create_firewall_rule_request)

```ruby
begin
  # Create a new firewall rule
  data, status_code, headers = api_instance.create_firewall_rule_with_http_info(project_id, firewall_name, create_firewall_rule_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <FirewallRule>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->create_firewall_rule_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |
| **create_firewall_rule_request** | [**CreateFirewallRuleRequest**](CreateFirewallRuleRequest.md) |  |  |

### Return type

[**FirewallRule**](FirewallRule.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## create_location_firewall_firewall_rule

> <FirewallRule> create_location_firewall_firewall_rule(location, project_id, firewall_name, firewall_rule_id, create_firewall_rule_request)

Create a new firewall rule

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallRuleApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall
firewall_rule_id = 'fraz0q3vbrpa7pkg7zbmah9csn' # String | ID of the firewall rule
create_firewall_rule_request = Ubicloud::CreateFirewallRuleRequest.new({cidr: 'cidr_example'}) # CreateFirewallRuleRequest | 

begin
  # Create a new firewall rule
  result = api_instance.create_location_firewall_firewall_rule(location, project_id, firewall_name, firewall_rule_id, create_firewall_rule_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->create_location_firewall_firewall_rule: #{e}"
end
```

#### Using the create_location_firewall_firewall_rule_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<FirewallRule>, Integer, Hash)> create_location_firewall_firewall_rule_with_http_info(location, project_id, firewall_name, firewall_rule_id, create_firewall_rule_request)

```ruby
begin
  # Create a new firewall rule
  data, status_code, headers = api_instance.create_location_firewall_firewall_rule_with_http_info(location, project_id, firewall_name, firewall_rule_id, create_firewall_rule_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <FirewallRule>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->create_location_firewall_firewall_rule_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |
| **firewall_rule_id** | **String** | ID of the firewall rule |  |
| **create_firewall_rule_request** | [**CreateFirewallRuleRequest**](CreateFirewallRuleRequest.md) |  |  |

### Return type

[**FirewallRule**](FirewallRule.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## create_location_firewall_rule

> <FirewallRule> create_location_firewall_rule(firewall_name, location, project_id, create_firewall_rule_request)

Create a new firewall rule

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallRuleApi.new
firewall_name = 'firewall_name_example' # String | Name of the firewall
location = 'eu-central-h1' # String | The Ubicloud location/region
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
create_firewall_rule_request = Ubicloud::CreateFirewallRuleRequest.new({cidr: 'cidr_example'}) # CreateFirewallRuleRequest | 

begin
  # Create a new firewall rule
  result = api_instance.create_location_firewall_rule(firewall_name, location, project_id, create_firewall_rule_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->create_location_firewall_rule: #{e}"
end
```

#### Using the create_location_firewall_rule_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<FirewallRule>, Integer, Hash)> create_location_firewall_rule_with_http_info(firewall_name, location, project_id, create_firewall_rule_request)

```ruby
begin
  # Create a new firewall rule
  data, status_code, headers = api_instance.create_location_firewall_rule_with_http_info(firewall_name, location, project_id, create_firewall_rule_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <FirewallRule>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->create_location_firewall_rule_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **firewall_name** | **String** | Name of the firewall |  |
| **location** | **String** | The Ubicloud location/region |  |
| **project_id** | **String** | ID of the project |  |
| **create_firewall_rule_request** | [**CreateFirewallRuleRequest**](CreateFirewallRuleRequest.md) |  |  |

### Return type

[**FirewallRule**](FirewallRule.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## delete_firewall_rule

> delete_firewall_rule(project_id, firewall_name, firewall_rule_id)

Delete a specific firewall rule

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallRuleApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall
firewall_rule_id = 'fraz0q3vbrpa7pkg7zbmah9csn' # String | ID of the firewall rule

begin
  # Delete a specific firewall rule
  api_instance.delete_firewall_rule(project_id, firewall_name, firewall_rule_id)
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->delete_firewall_rule: #{e}"
end
```

#### Using the delete_firewall_rule_with_http_info variant

This returns an Array which contains the response data (`nil` in this case), status code and headers.

> <Array(nil, Integer, Hash)> delete_firewall_rule_with_http_info(project_id, firewall_name, firewall_rule_id)

```ruby
begin
  # Delete a specific firewall rule
  data, status_code, headers = api_instance.delete_firewall_rule_with_http_info(project_id, firewall_name, firewall_rule_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => nil
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->delete_firewall_rule_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |
| **firewall_rule_id** | **String** | ID of the firewall rule |  |

### Return type

nil (empty response body)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## delete_location_firewall_firewall_rule

> delete_location_firewall_firewall_rule(location, project_id, firewall_name, firewall_rule_id)

Delete a specific firewall rule

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallRuleApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall
firewall_rule_id = 'fraz0q3vbrpa7pkg7zbmah9csn' # String | ID of the firewall rule

begin
  # Delete a specific firewall rule
  api_instance.delete_location_firewall_firewall_rule(location, project_id, firewall_name, firewall_rule_id)
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->delete_location_firewall_firewall_rule: #{e}"
end
```

#### Using the delete_location_firewall_firewall_rule_with_http_info variant

This returns an Array which contains the response data (`nil` in this case), status code and headers.

> <Array(nil, Integer, Hash)> delete_location_firewall_firewall_rule_with_http_info(location, project_id, firewall_name, firewall_rule_id)

```ruby
begin
  # Delete a specific firewall rule
  data, status_code, headers = api_instance.delete_location_firewall_firewall_rule_with_http_info(location, project_id, firewall_name, firewall_rule_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => nil
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->delete_location_firewall_firewall_rule_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |
| **firewall_rule_id** | **String** | ID of the firewall rule |  |

### Return type

nil (empty response body)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## delete_location_postgres_firewall_rule

> delete_location_postgres_firewall_rule(project_id, location, postgres_database_name, firewall_rule_id)

Delete a specific firewall rule

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallRuleApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
postgres_database_name = 'postgres_database_name_example' # String | Postgres database name
firewall_rule_id = 'pfmjgkgbktw62k53005jpx8tt7' # String | ID of the postgres firewall rule

begin
  # Delete a specific firewall rule
  api_instance.delete_location_postgres_firewall_rule(project_id, location, postgres_database_name, firewall_rule_id)
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->delete_location_postgres_firewall_rule: #{e}"
end
```

#### Using the delete_location_postgres_firewall_rule_with_http_info variant

This returns an Array which contains the response data (`nil` in this case), status code and headers.

> <Array(nil, Integer, Hash)> delete_location_postgres_firewall_rule_with_http_info(project_id, location, postgres_database_name, firewall_rule_id)

```ruby
begin
  # Delete a specific firewall rule
  data, status_code, headers = api_instance.delete_location_postgres_firewall_rule_with_http_info(project_id, location, postgres_database_name, firewall_rule_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => nil
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->delete_location_postgres_firewall_rule_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **postgres_database_name** | **String** | Postgres database name |  |
| **firewall_rule_id** | **String** | ID of the postgres firewall rule |  |

### Return type

nil (empty response body)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## get_firewall_rule_details

> <FirewallRule> get_firewall_rule_details(project_id, firewall_name, firewall_rule_id)

Get details of a firewall rule

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallRuleApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall
firewall_rule_id = 'fraz0q3vbrpa7pkg7zbmah9csn' # String | ID of the firewall rule

begin
  # Get details of a firewall rule
  result = api_instance.get_firewall_rule_details(project_id, firewall_name, firewall_rule_id)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->get_firewall_rule_details: #{e}"
end
```

#### Using the get_firewall_rule_details_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<FirewallRule>, Integer, Hash)> get_firewall_rule_details_with_http_info(project_id, firewall_name, firewall_rule_id)

```ruby
begin
  # Get details of a firewall rule
  data, status_code, headers = api_instance.get_firewall_rule_details_with_http_info(project_id, firewall_name, firewall_rule_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <FirewallRule>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->get_firewall_rule_details_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |
| **firewall_rule_id** | **String** | ID of the firewall rule |  |

### Return type

[**FirewallRule**](FirewallRule.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## get_location_firewall_firewall_rule_details

> <FirewallRule> get_location_firewall_firewall_rule_details(location, project_id, firewall_name, firewall_rule_id)

Get details of a firewall rule

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallRuleApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall
firewall_rule_id = 'fraz0q3vbrpa7pkg7zbmah9csn' # String | ID of the firewall rule

begin
  # Get details of a firewall rule
  result = api_instance.get_location_firewall_firewall_rule_details(location, project_id, firewall_name, firewall_rule_id)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->get_location_firewall_firewall_rule_details: #{e}"
end
```

#### Using the get_location_firewall_firewall_rule_details_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<FirewallRule>, Integer, Hash)> get_location_firewall_firewall_rule_details_with_http_info(location, project_id, firewall_name, firewall_rule_id)

```ruby
begin
  # Get details of a firewall rule
  data, status_code, headers = api_instance.get_location_firewall_firewall_rule_details_with_http_info(location, project_id, firewall_name, firewall_rule_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <FirewallRule>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallRuleApi->get_location_firewall_firewall_rule_details_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |
| **firewall_rule_id** | **String** | ID of the firewall rule |  |

### Return type

[**FirewallRule**](FirewallRule.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

