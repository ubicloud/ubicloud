# Ubicloud::PrivateSubnetApi

All URIs are relative to *https://api.ubicloud.com*

| Method | HTTP request | Description |
| ------ | ------------ | ----------- |
| [**connect_private_subnet**](PrivateSubnetApi.md#connect_private_subnet) | **POST** /project/{project_id}/location/{location}/private-subnet/{private_subnet_name}/connect | Connect private subnet to another private subnet |
| [**create_private_subnet**](PrivateSubnetApi.md#create_private_subnet) | **POST** /project/{project_id}/location/{location}/private-subnet/{private_subnet_name} | Create a new Private Subnet in a specific location of a project |
| [**delete_private_subnet**](PrivateSubnetApi.md#delete_private_subnet) | **DELETE** /project/{project_id}/location/{location}/private-subnet/{private_subnet_name} | Delete a specific Private Subnet |
| [**disconnect_private_subnet**](PrivateSubnetApi.md#disconnect_private_subnet) | **POST** /project/{project_id}/location/{location}/private-subnet/{private_subnet_name}/disconnect/{private_subnet_id} | Disconnect private subnet from another private subnet |
| [**get_private_subnet_details**](PrivateSubnetApi.md#get_private_subnet_details) | **GET** /project/{project_id}/location/{location}/private-subnet/{private_subnet_name} | Get details of a specific Private Subnet in a location |
| [**list_location_private_subnets**](PrivateSubnetApi.md#list_location_private_subnets) | **GET** /project/{project_id}/location/{location}/private-subnet | List Private Subnets in a specific location of a project |
| [**list_pss**](PrivateSubnetApi.md#list_pss) | **GET** /project/{project_id}/private-subnet | List visible Private Subnets |


## connect_private_subnet

> <PrivateSubnet> connect_private_subnet(project_id, location, private_subnet_name, connect_private_subnet_request)

Connect private subnet to another private subnet

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PrivateSubnetApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
private_subnet_name = 'private_subnet_name_example' # String | Private subnet name
connect_private_subnet_request = Ubicloud::ConnectPrivateSubnetRequest.new # ConnectPrivateSubnetRequest | 

begin
  # Connect private subnet to another private subnet
  result = api_instance.connect_private_subnet(project_id, location, private_subnet_name, connect_private_subnet_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->connect_private_subnet: #{e}"
end
```

#### Using the connect_private_subnet_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<PrivateSubnet>, Integer, Hash)> connect_private_subnet_with_http_info(project_id, location, private_subnet_name, connect_private_subnet_request)

```ruby
begin
  # Connect private subnet to another private subnet
  data, status_code, headers = api_instance.connect_private_subnet_with_http_info(project_id, location, private_subnet_name, connect_private_subnet_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <PrivateSubnet>
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->connect_private_subnet_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **private_subnet_name** | **String** | Private subnet name |  |
| **connect_private_subnet_request** | [**ConnectPrivateSubnetRequest**](ConnectPrivateSubnetRequest.md) |  |  |

### Return type

[**PrivateSubnet**](PrivateSubnet.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## create_private_subnet

> <PrivateSubnet> create_private_subnet(project_id, location, private_subnet_name, opts)

Create a new Private Subnet in a specific location of a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PrivateSubnetApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
private_subnet_name = 'private_subnet_name_example' # String | Private subnet name
opts = {
  create_private_subnet_request: Ubicloud::CreatePrivateSubnetRequest.new # CreatePrivateSubnetRequest | 
}

begin
  # Create a new Private Subnet in a specific location of a project
  result = api_instance.create_private_subnet(project_id, location, private_subnet_name, opts)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->create_private_subnet: #{e}"
end
```

#### Using the create_private_subnet_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<PrivateSubnet>, Integer, Hash)> create_private_subnet_with_http_info(project_id, location, private_subnet_name, opts)

```ruby
begin
  # Create a new Private Subnet in a specific location of a project
  data, status_code, headers = api_instance.create_private_subnet_with_http_info(project_id, location, private_subnet_name, opts)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <PrivateSubnet>
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->create_private_subnet_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **private_subnet_name** | **String** | Private subnet name |  |
| **create_private_subnet_request** | [**CreatePrivateSubnetRequest**](CreatePrivateSubnetRequest.md) |  | [optional] |

### Return type

[**PrivateSubnet**](PrivateSubnet.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## delete_private_subnet

> delete_private_subnet(project_id, location, private_subnet_name)

Delete a specific Private Subnet

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PrivateSubnetApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
private_subnet_name = 'private_subnet_name_example' # String | Private subnet name

begin
  # Delete a specific Private Subnet
  api_instance.delete_private_subnet(project_id, location, private_subnet_name)
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->delete_private_subnet: #{e}"
end
```

#### Using the delete_private_subnet_with_http_info variant

This returns an Array which contains the response data (`nil` in this case), status code and headers.

> <Array(nil, Integer, Hash)> delete_private_subnet_with_http_info(project_id, location, private_subnet_name)

```ruby
begin
  # Delete a specific Private Subnet
  data, status_code, headers = api_instance.delete_private_subnet_with_http_info(project_id, location, private_subnet_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => nil
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->delete_private_subnet_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **private_subnet_name** | **String** | Private subnet name |  |

### Return type

nil (empty response body)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## disconnect_private_subnet

> <PrivateSubnet> disconnect_private_subnet(project_id, location, private_subnet_name, private_subnet_id)

Disconnect private subnet from another private subnet

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PrivateSubnetApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
private_subnet_name = 'private_subnet_name_example' # String | Private subnet name
private_subnet_id = 'pskkmx0f2vke4h36nk9cm8v8q0' # String | ID of the private subnet

begin
  # Disconnect private subnet from another private subnet
  result = api_instance.disconnect_private_subnet(project_id, location, private_subnet_name, private_subnet_id)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->disconnect_private_subnet: #{e}"
end
```

#### Using the disconnect_private_subnet_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<PrivateSubnet>, Integer, Hash)> disconnect_private_subnet_with_http_info(project_id, location, private_subnet_name, private_subnet_id)

```ruby
begin
  # Disconnect private subnet from another private subnet
  data, status_code, headers = api_instance.disconnect_private_subnet_with_http_info(project_id, location, private_subnet_name, private_subnet_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <PrivateSubnet>
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->disconnect_private_subnet_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **private_subnet_name** | **String** | Private subnet name |  |
| **private_subnet_id** | **String** | ID of the private subnet |  |

### Return type

[**PrivateSubnet**](PrivateSubnet.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## get_private_subnet_details

> <PrivateSubnet> get_private_subnet_details(project_id, location, private_subnet_name)

Get details of a specific Private Subnet in a location

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PrivateSubnetApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
private_subnet_name = 'private_subnet_name_example' # String | Private subnet name

begin
  # Get details of a specific Private Subnet in a location
  result = api_instance.get_private_subnet_details(project_id, location, private_subnet_name)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->get_private_subnet_details: #{e}"
end
```

#### Using the get_private_subnet_details_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<PrivateSubnet>, Integer, Hash)> get_private_subnet_details_with_http_info(project_id, location, private_subnet_name)

```ruby
begin
  # Get details of a specific Private Subnet in a location
  data, status_code, headers = api_instance.get_private_subnet_details_with_http_info(project_id, location, private_subnet_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <PrivateSubnet>
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->get_private_subnet_details_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **private_subnet_name** | **String** | Private subnet name |  |

### Return type

[**PrivateSubnet**](PrivateSubnet.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## list_location_private_subnets

> <ListLocationPrivateSubnets200Response> list_location_private_subnets(project_id, location, opts)

List Private Subnets in a specific location of a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PrivateSubnetApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
opts = {
  start_after: 'start_after_example', # String | Pagination - Start after
  page_size: 56, # Integer | Pagination - Page size
  order_column: 'order_column_example' # String | Pagination - Order column
}

begin
  # List Private Subnets in a specific location of a project
  result = api_instance.list_location_private_subnets(project_id, location, opts)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->list_location_private_subnets: #{e}"
end
```

#### Using the list_location_private_subnets_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<ListLocationPrivateSubnets200Response>, Integer, Hash)> list_location_private_subnets_with_http_info(project_id, location, opts)

```ruby
begin
  # List Private Subnets in a specific location of a project
  data, status_code, headers = api_instance.list_location_private_subnets_with_http_info(project_id, location, opts)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <ListLocationPrivateSubnets200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->list_location_private_subnets_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **start_after** | **String** | Pagination - Start after | [optional] |
| **page_size** | **Integer** | Pagination - Page size | [optional][default to 10] |
| **order_column** | **String** | Pagination - Order column | [optional][default to &#39;id&#39;] |

### Return type

[**ListLocationPrivateSubnets200Response**](ListLocationPrivateSubnets200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## list_pss

> <ListLocationPrivateSubnets200Response> list_pss(project_id, opts)

List visible Private Subnets

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::PrivateSubnetApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
opts = {
  start_after: 'start_after_example', # String | Pagination - Start after
  page_size: 56, # Integer | Pagination - Page size
  order_column: 'order_column_example' # String | Pagination - Order column
}

begin
  # List visible Private Subnets
  result = api_instance.list_pss(project_id, opts)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->list_pss: #{e}"
end
```

#### Using the list_pss_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<ListLocationPrivateSubnets200Response>, Integer, Hash)> list_pss_with_http_info(project_id, opts)

```ruby
begin
  # List visible Private Subnets
  data, status_code, headers = api_instance.list_pss_with_http_info(project_id, opts)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <ListLocationPrivateSubnets200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling PrivateSubnetApi->list_pss_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **start_after** | **String** | Pagination - Start after | [optional] |
| **page_size** | **Integer** | Pagination - Page size | [optional][default to 10] |
| **order_column** | **String** | Pagination - Order column | [optional][default to &#39;id&#39;] |

### Return type

[**ListLocationPrivateSubnets200Response**](ListLocationPrivateSubnets200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

