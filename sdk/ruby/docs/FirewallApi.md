# Ubicloud::FirewallApi

All URIs are relative to *https://api.ubicloud.com*

| Method | HTTP request | Description |
| ------ | ------------ | ----------- |
| [**action_location_firewall_attach_subnet**](FirewallApi.md#action_location_firewall_attach_subnet) | **POST** /project/{project_id}/location/{location}/firewall/{firewall_name}/attach-subnet | Attach a subnet to firewall |
| [**action_location_firewall_detach_subnet**](FirewallApi.md#action_location_firewall_detach_subnet) | **POST** /project/{project_id}/location/{location}/firewall/{firewall_name}/detach-subnet | Detach a subnet from firewall |
| [**create_firewall**](FirewallApi.md#create_firewall) | **POST** /project/{project_id}/firewall | Create a new firewall |
| [**create_location_firewall**](FirewallApi.md#create_location_firewall) | **POST** /project/{project_id}/location/{location}/firewall/{firewall_name} | Create a new firewall |
| [**delete_firewall**](FirewallApi.md#delete_firewall) | **DELETE** /project/{project_id}/firewall/{firewall_name} | Delete a specific firewall |
| [**delete_location_firewall**](FirewallApi.md#delete_location_firewall) | **DELETE** /project/{project_id}/location/{location}/firewall/{firewall_name} | Delete a specific firewall |
| [**get_firewall**](FirewallApi.md#get_firewall) | **GET** /project/{project_id}/firewall | Return the list of firewalls in the project |
| [**get_firewall_details**](FirewallApi.md#get_firewall_details) | **GET** /project/{project_id}/firewall/{firewall_name} | Get details of a specific firewall |
| [**get_location_firewall**](FirewallApi.md#get_location_firewall) | **GET** /project/{project_id}/location/{location}/firewall | Return the list of firewalls in the project and location |
| [**get_location_firewall_details**](FirewallApi.md#get_location_firewall_details) | **GET** /project/{project_id}/location/{location}/firewall/{firewall_name} | Get details of a specific firewall |


## action_location_firewall_attach_subnet

> <GetLocationFirewallDetails200Response> action_location_firewall_attach_subnet(location, project_id, firewall_name, action_location_firewall_attach_subnet_request)

Attach a subnet to firewall

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall
action_location_firewall_attach_subnet_request = Ubicloud::ActionLocationFirewallAttachSubnetRequest.new({private_subnet_id: 'private_subnet_id_example'}) # ActionLocationFirewallAttachSubnetRequest | 

begin
  # Attach a subnet to firewall
  result = api_instance.action_location_firewall_attach_subnet(location, project_id, firewall_name, action_location_firewall_attach_subnet_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->action_location_firewall_attach_subnet: #{e}"
end
```

#### Using the action_location_firewall_attach_subnet_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetLocationFirewallDetails200Response>, Integer, Hash)> action_location_firewall_attach_subnet_with_http_info(location, project_id, firewall_name, action_location_firewall_attach_subnet_request)

```ruby
begin
  # Attach a subnet to firewall
  data, status_code, headers = api_instance.action_location_firewall_attach_subnet_with_http_info(location, project_id, firewall_name, action_location_firewall_attach_subnet_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetLocationFirewallDetails200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->action_location_firewall_attach_subnet_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |
| **action_location_firewall_attach_subnet_request** | [**ActionLocationFirewallAttachSubnetRequest**](ActionLocationFirewallAttachSubnetRequest.md) |  |  |

### Return type

[**GetLocationFirewallDetails200Response**](GetLocationFirewallDetails200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## action_location_firewall_detach_subnet

> <GetLocationFirewallDetails200Response> action_location_firewall_detach_subnet(location, project_id, firewall_name, action_location_firewall_detach_subnet_request)

Detach a subnet from firewall

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall
action_location_firewall_detach_subnet_request = Ubicloud::ActionLocationFirewallDetachSubnetRequest.new({private_subnet_id: 'private_subnet_id_example'}) # ActionLocationFirewallDetachSubnetRequest | 

begin
  # Detach a subnet from firewall
  result = api_instance.action_location_firewall_detach_subnet(location, project_id, firewall_name, action_location_firewall_detach_subnet_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->action_location_firewall_detach_subnet: #{e}"
end
```

#### Using the action_location_firewall_detach_subnet_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetLocationFirewallDetails200Response>, Integer, Hash)> action_location_firewall_detach_subnet_with_http_info(location, project_id, firewall_name, action_location_firewall_detach_subnet_request)

```ruby
begin
  # Detach a subnet from firewall
  data, status_code, headers = api_instance.action_location_firewall_detach_subnet_with_http_info(location, project_id, firewall_name, action_location_firewall_detach_subnet_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetLocationFirewallDetails200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->action_location_firewall_detach_subnet_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |
| **action_location_firewall_detach_subnet_request** | [**ActionLocationFirewallDetachSubnetRequest**](ActionLocationFirewallDetachSubnetRequest.md) |  |  |

### Return type

[**GetLocationFirewallDetails200Response**](GetLocationFirewallDetails200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## create_firewall

> <Firewall> create_firewall(project_id, create_firewall_request)

Create a new firewall

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
create_firewall_request = Ubicloud::CreateFirewallRequest.new({name: 'name_example'}) # CreateFirewallRequest | 

begin
  # Create a new firewall
  result = api_instance.create_firewall(project_id, create_firewall_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->create_firewall: #{e}"
end
```

#### Using the create_firewall_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<Firewall>, Integer, Hash)> create_firewall_with_http_info(project_id, create_firewall_request)

```ruby
begin
  # Create a new firewall
  data, status_code, headers = api_instance.create_firewall_with_http_info(project_id, create_firewall_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <Firewall>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->create_firewall_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **create_firewall_request** | [**CreateFirewallRequest**](CreateFirewallRequest.md) |  |  |

### Return type

[**Firewall**](Firewall.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## create_location_firewall

> <Firewall> create_location_firewall(location, project_id, firewall_name, create_location_firewall_request)

Create a new firewall

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall
create_location_firewall_request = Ubicloud::CreateLocationFirewallRequest.new # CreateLocationFirewallRequest | 

begin
  # Create a new firewall
  result = api_instance.create_location_firewall(location, project_id, firewall_name, create_location_firewall_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->create_location_firewall: #{e}"
end
```

#### Using the create_location_firewall_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<Firewall>, Integer, Hash)> create_location_firewall_with_http_info(location, project_id, firewall_name, create_location_firewall_request)

```ruby
begin
  # Create a new firewall
  data, status_code, headers = api_instance.create_location_firewall_with_http_info(location, project_id, firewall_name, create_location_firewall_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <Firewall>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->create_location_firewall_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |
| **create_location_firewall_request** | [**CreateLocationFirewallRequest**](CreateLocationFirewallRequest.md) |  |  |

### Return type

[**Firewall**](Firewall.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## delete_firewall

> delete_firewall(project_id, firewall_name)

Delete a specific firewall

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall

begin
  # Delete a specific firewall
  api_instance.delete_firewall(project_id, firewall_name)
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->delete_firewall: #{e}"
end
```

#### Using the delete_firewall_with_http_info variant

This returns an Array which contains the response data (`nil` in this case), status code and headers.

> <Array(nil, Integer, Hash)> delete_firewall_with_http_info(project_id, firewall_name)

```ruby
begin
  # Delete a specific firewall
  data, status_code, headers = api_instance.delete_firewall_with_http_info(project_id, firewall_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => nil
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->delete_firewall_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |

### Return type

nil (empty response body)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## delete_location_firewall

> delete_location_firewall(location, project_id, firewall_name)

Delete a specific firewall

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall

begin
  # Delete a specific firewall
  api_instance.delete_location_firewall(location, project_id, firewall_name)
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->delete_location_firewall: #{e}"
end
```

#### Using the delete_location_firewall_with_http_info variant

This returns an Array which contains the response data (`nil` in this case), status code and headers.

> <Array(nil, Integer, Hash)> delete_location_firewall_with_http_info(location, project_id, firewall_name)

```ruby
begin
  # Delete a specific firewall
  data, status_code, headers = api_instance.delete_location_firewall_with_http_info(location, project_id, firewall_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => nil
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->delete_location_firewall_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |

### Return type

nil (empty response body)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## get_firewall

> <GetFirewall200Response> get_firewall(project_id)

Return the list of firewalls in the project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project

begin
  # Return the list of firewalls in the project
  result = api_instance.get_firewall(project_id)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->get_firewall: #{e}"
end
```

#### Using the get_firewall_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetFirewall200Response>, Integer, Hash)> get_firewall_with_http_info(project_id)

```ruby
begin
  # Return the list of firewalls in the project
  data, status_code, headers = api_instance.get_firewall_with_http_info(project_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetFirewall200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->get_firewall_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |

### Return type

[**GetFirewall200Response**](GetFirewall200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## get_firewall_details

> <Firewall> get_firewall_details(project_id, firewall_name)

Get details of a specific firewall

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall

begin
  # Get details of a specific firewall
  result = api_instance.get_firewall_details(project_id, firewall_name)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->get_firewall_details: #{e}"
end
```

#### Using the get_firewall_details_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<Firewall>, Integer, Hash)> get_firewall_details_with_http_info(project_id, firewall_name)

```ruby
begin
  # Get details of a specific firewall
  data, status_code, headers = api_instance.get_firewall_details_with_http_info(project_id, firewall_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <Firewall>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->get_firewall_details_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |

### Return type

[**Firewall**](Firewall.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## get_location_firewall

> <GetFirewall200Response> get_location_firewall(location, project_id)

Return the list of firewalls in the project and location

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project

begin
  # Return the list of firewalls in the project and location
  result = api_instance.get_location_firewall(location, project_id)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->get_location_firewall: #{e}"
end
```

#### Using the get_location_firewall_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetFirewall200Response>, Integer, Hash)> get_location_firewall_with_http_info(location, project_id)

```ruby
begin
  # Return the list of firewalls in the project and location
  data, status_code, headers = api_instance.get_location_firewall_with_http_info(location, project_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetFirewall200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->get_location_firewall_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **project_id** | **String** | ID of the project |  |

### Return type

[**GetFirewall200Response**](GetFirewall200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## get_location_firewall_details

> <GetLocationFirewallDetails200Response> get_location_firewall_details(location, project_id, firewall_name)

Get details of a specific firewall

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::FirewallApi.new
location = 'eu-central-h1' # String | The Ubicloud location/region
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
firewall_name = 'firewall_name_example' # String | Name of the firewall

begin
  # Get details of a specific firewall
  result = api_instance.get_location_firewall_details(location, project_id, firewall_name)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->get_location_firewall_details: #{e}"
end
```

#### Using the get_location_firewall_details_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetLocationFirewallDetails200Response>, Integer, Hash)> get_location_firewall_details_with_http_info(location, project_id, firewall_name)

```ruby
begin
  # Get details of a specific firewall
  data, status_code, headers = api_instance.get_location_firewall_details_with_http_info(location, project_id, firewall_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetLocationFirewallDetails200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling FirewallApi->get_location_firewall_details_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **location** | **String** | The Ubicloud location/region |  |
| **project_id** | **String** | ID of the project |  |
| **firewall_name** | **String** | Name of the firewall |  |

### Return type

[**GetLocationFirewallDetails200Response**](GetLocationFirewallDetails200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

