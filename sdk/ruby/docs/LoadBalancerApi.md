# Ubicloud::LoadBalancerApi

All URIs are relative to *https://api.ubicloud.com*

| Method | HTTP request | Description |
| ------ | ------------ | ----------- |
| [**attach_vm_location_load_balancer**](LoadBalancerApi.md#attach_vm_location_load_balancer) | **POST** /project/{project_id}/location/{location}/load-balancer/{load_balancer_name}/attach-vm | Attach a VM to a Load Balancer in a specific location of a project |
| [**create_load_balancer**](LoadBalancerApi.md#create_load_balancer) | **POST** /project/{project_id}/load-balancer/{load_balancer_name} | Create a new Load Balancer in a project |
| [**create_location_load_balancer**](LoadBalancerApi.md#create_location_load_balancer) | **POST** /project/{project_id}/location/{location}/load-balancer/{load_balancer_name} | Create a new Load Balancer in a specific location of a project |
| [**delete_load_balancer**](LoadBalancerApi.md#delete_load_balancer) | **DELETE** /project/{project_id}/location/{location}/load-balancer/{load_balancer_name} | Delete a specific Load Balancer |
| [**detach_vm_location_load_balancer**](LoadBalancerApi.md#detach_vm_location_load_balancer) | **POST** /project/{project_id}/location/{location}/load-balancer/{load_balancer_name}/detach-vm | Detach a VM from a Load Balancer in a specific location of a project |
| [**get_load_balancer**](LoadBalancerApi.md#get_load_balancer) | **GET** /project/{project_id}/load-balancer/{load_balancer_name} | Get details of a specific Load Balancer |
| [**get_load_balancer_details**](LoadBalancerApi.md#get_load_balancer_details) | **GET** /project/{project_id}/location/{location}/load-balancer/{load_balancer_name} | Get details of a specific Load Balancer in a location |
| [**list_load_balancers**](LoadBalancerApi.md#list_load_balancers) | **GET** /project/{project_id}/load-balancer | List Load Balancers in a specific project |
| [**list_location_load_balancers**](LoadBalancerApi.md#list_location_load_balancers) | **GET** /project/{project_id}/location/{location}/load-balancer | List Load Balancers in a specific location of a project |
| [**patch_location_load_balancer**](LoadBalancerApi.md#patch_location_load_balancer) | **PATCH** /project/{project_id}/location/{location}/load-balancer/{load_balancer_name} | Update a Load Balancer in a specific location of a project |


## attach_vm_location_load_balancer

> <GetLoadBalancer200Response> attach_vm_location_load_balancer(project_id, location, load_balancer_name, attach_vm_location_load_balancer_request)

Attach a VM to a Load Balancer in a specific location of a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::LoadBalancerApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
load_balancer_name = 'load_balancer_name_example' # String | Name of the load balancer
attach_vm_location_load_balancer_request = Ubicloud::AttachVmLocationLoadBalancerRequest.new({vm_id: 'vm_id_example'}) # AttachVmLocationLoadBalancerRequest | 

begin
  # Attach a VM to a Load Balancer in a specific location of a project
  result = api_instance.attach_vm_location_load_balancer(project_id, location, load_balancer_name, attach_vm_location_load_balancer_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->attach_vm_location_load_balancer: #{e}"
end
```

#### Using the attach_vm_location_load_balancer_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetLoadBalancer200Response>, Integer, Hash)> attach_vm_location_load_balancer_with_http_info(project_id, location, load_balancer_name, attach_vm_location_load_balancer_request)

```ruby
begin
  # Attach a VM to a Load Balancer in a specific location of a project
  data, status_code, headers = api_instance.attach_vm_location_load_balancer_with_http_info(project_id, location, load_balancer_name, attach_vm_location_load_balancer_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetLoadBalancer200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->attach_vm_location_load_balancer_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **load_balancer_name** | **String** | Name of the load balancer |  |
| **attach_vm_location_load_balancer_request** | [**AttachVmLocationLoadBalancerRequest**](AttachVmLocationLoadBalancerRequest.md) |  |  |

### Return type

[**GetLoadBalancer200Response**](GetLoadBalancer200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## create_load_balancer

> <GetLoadBalancer200Response> create_load_balancer(project_id, load_balancer_name, create_load_balancer_request)

Create a new Load Balancer in a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::LoadBalancerApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
load_balancer_name = 'load_balancer_name_example' # String | Name of the load balancer
create_load_balancer_request = Ubicloud::CreateLoadBalancerRequest.new({algorithm: 'algorithm_example', dst_port: 37, health_check_protocol: 'health_check_protocol_example', private_subnet_id: 'private_subnet_id_example', src_port: 37}) # CreateLoadBalancerRequest | 

begin
  # Create a new Load Balancer in a project
  result = api_instance.create_load_balancer(project_id, load_balancer_name, create_load_balancer_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->create_load_balancer: #{e}"
end
```

#### Using the create_load_balancer_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetLoadBalancer200Response>, Integer, Hash)> create_load_balancer_with_http_info(project_id, load_balancer_name, create_load_balancer_request)

```ruby
begin
  # Create a new Load Balancer in a project
  data, status_code, headers = api_instance.create_load_balancer_with_http_info(project_id, load_balancer_name, create_load_balancer_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetLoadBalancer200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->create_load_balancer_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **load_balancer_name** | **String** | Name of the load balancer |  |
| **create_load_balancer_request** | [**CreateLoadBalancerRequest**](CreateLoadBalancerRequest.md) |  |  |

### Return type

[**GetLoadBalancer200Response**](GetLoadBalancer200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## create_location_load_balancer

> <GetLoadBalancer200Response> create_location_load_balancer(project_id, location, load_balancer_name, create_load_balancer_request)

Create a new Load Balancer in a specific location of a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::LoadBalancerApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
load_balancer_name = 'load_balancer_name_example' # String | Name of the load balancer
create_load_balancer_request = Ubicloud::CreateLoadBalancerRequest.new({algorithm: 'algorithm_example', dst_port: 37, health_check_protocol: 'health_check_protocol_example', private_subnet_id: 'private_subnet_id_example', src_port: 37}) # CreateLoadBalancerRequest | 

begin
  # Create a new Load Balancer in a specific location of a project
  result = api_instance.create_location_load_balancer(project_id, location, load_balancer_name, create_load_balancer_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->create_location_load_balancer: #{e}"
end
```

#### Using the create_location_load_balancer_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetLoadBalancer200Response>, Integer, Hash)> create_location_load_balancer_with_http_info(project_id, location, load_balancer_name, create_load_balancer_request)

```ruby
begin
  # Create a new Load Balancer in a specific location of a project
  data, status_code, headers = api_instance.create_location_load_balancer_with_http_info(project_id, location, load_balancer_name, create_load_balancer_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetLoadBalancer200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->create_location_load_balancer_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **load_balancer_name** | **String** | Name of the load balancer |  |
| **create_load_balancer_request** | [**CreateLoadBalancerRequest**](CreateLoadBalancerRequest.md) |  |  |

### Return type

[**GetLoadBalancer200Response**](GetLoadBalancer200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## delete_load_balancer

> delete_load_balancer(project_id, location, load_balancer_name)

Delete a specific Load Balancer

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::LoadBalancerApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
load_balancer_name = 'load_balancer_name_example' # String | Name of the load balancer

begin
  # Delete a specific Load Balancer
  api_instance.delete_load_balancer(project_id, location, load_balancer_name)
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->delete_load_balancer: #{e}"
end
```

#### Using the delete_load_balancer_with_http_info variant

This returns an Array which contains the response data (`nil` in this case), status code and headers.

> <Array(nil, Integer, Hash)> delete_load_balancer_with_http_info(project_id, location, load_balancer_name)

```ruby
begin
  # Delete a specific Load Balancer
  data, status_code, headers = api_instance.delete_load_balancer_with_http_info(project_id, location, load_balancer_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => nil
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->delete_load_balancer_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **load_balancer_name** | **String** | Name of the load balancer |  |

### Return type

nil (empty response body)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## detach_vm_location_load_balancer

> <GetLoadBalancer200Response> detach_vm_location_load_balancer(project_id, location, load_balancer_name, detach_vm_location_load_balancer_request)

Detach a VM from a Load Balancer in a specific location of a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::LoadBalancerApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
load_balancer_name = 'load_balancer_name_example' # String | Name of the load balancer
detach_vm_location_load_balancer_request = Ubicloud::DetachVmLocationLoadBalancerRequest.new({vm_id: 'vm_id_example'}) # DetachVmLocationLoadBalancerRequest | 

begin
  # Detach a VM from a Load Balancer in a specific location of a project
  result = api_instance.detach_vm_location_load_balancer(project_id, location, load_balancer_name, detach_vm_location_load_balancer_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->detach_vm_location_load_balancer: #{e}"
end
```

#### Using the detach_vm_location_load_balancer_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetLoadBalancer200Response>, Integer, Hash)> detach_vm_location_load_balancer_with_http_info(project_id, location, load_balancer_name, detach_vm_location_load_balancer_request)

```ruby
begin
  # Detach a VM from a Load Balancer in a specific location of a project
  data, status_code, headers = api_instance.detach_vm_location_load_balancer_with_http_info(project_id, location, load_balancer_name, detach_vm_location_load_balancer_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetLoadBalancer200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->detach_vm_location_load_balancer_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **load_balancer_name** | **String** | Name of the load balancer |  |
| **detach_vm_location_load_balancer_request** | [**DetachVmLocationLoadBalancerRequest**](DetachVmLocationLoadBalancerRequest.md) |  |  |

### Return type

[**GetLoadBalancer200Response**](GetLoadBalancer200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## get_load_balancer

> <GetLoadBalancer200Response> get_load_balancer(project_id, load_balancer_name)

Get details of a specific Load Balancer

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::LoadBalancerApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
load_balancer_name = 'load_balancer_name_example' # String | Name of the load balancer

begin
  # Get details of a specific Load Balancer
  result = api_instance.get_load_balancer(project_id, load_balancer_name)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->get_load_balancer: #{e}"
end
```

#### Using the get_load_balancer_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetLoadBalancer200Response>, Integer, Hash)> get_load_balancer_with_http_info(project_id, load_balancer_name)

```ruby
begin
  # Get details of a specific Load Balancer
  data, status_code, headers = api_instance.get_load_balancer_with_http_info(project_id, load_balancer_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetLoadBalancer200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->get_load_balancer_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **load_balancer_name** | **String** | Name of the load balancer |  |

### Return type

[**GetLoadBalancer200Response**](GetLoadBalancer200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## get_load_balancer_details

> <GetLoadBalancer200Response> get_load_balancer_details(project_id, location, load_balancer_name)

Get details of a specific Load Balancer in a location

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::LoadBalancerApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
load_balancer_name = 'load_balancer_name_example' # String | Name of the load balancer

begin
  # Get details of a specific Load Balancer in a location
  result = api_instance.get_load_balancer_details(project_id, location, load_balancer_name)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->get_load_balancer_details: #{e}"
end
```

#### Using the get_load_balancer_details_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetLoadBalancer200Response>, Integer, Hash)> get_load_balancer_details_with_http_info(project_id, location, load_balancer_name)

```ruby
begin
  # Get details of a specific Load Balancer in a location
  data, status_code, headers = api_instance.get_load_balancer_details_with_http_info(project_id, location, load_balancer_name)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetLoadBalancer200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->get_load_balancer_details_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **load_balancer_name** | **String** | Name of the load balancer |  |

### Return type

[**GetLoadBalancer200Response**](GetLoadBalancer200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## list_load_balancers

> <ListLoadBalancers200Response> list_load_balancers(project_id, opts)

List Load Balancers in a specific project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::LoadBalancerApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
opts = {
  start_after: 'start_after_example', # String | Pagination - Start after
  page_size: 56, # Integer | Pagination - Page size
  order_column: 'order_column_example' # String | Pagination - Order column
}

begin
  # List Load Balancers in a specific project
  result = api_instance.list_load_balancers(project_id, opts)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->list_load_balancers: #{e}"
end
```

#### Using the list_load_balancers_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<ListLoadBalancers200Response>, Integer, Hash)> list_load_balancers_with_http_info(project_id, opts)

```ruby
begin
  # List Load Balancers in a specific project
  data, status_code, headers = api_instance.list_load_balancers_with_http_info(project_id, opts)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <ListLoadBalancers200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->list_load_balancers_with_http_info: #{e}"
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

[**ListLoadBalancers200Response**](ListLoadBalancers200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## list_location_load_balancers

> <ListLoadBalancers200Response> list_location_load_balancers(project_id, location, opts)

List Load Balancers in a specific location of a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::LoadBalancerApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
opts = {
  start_after: 'start_after_example', # String | Pagination - Start after
  page_size: 56, # Integer | Pagination - Page size
  order_column: 'order_column_example' # String | Pagination - Order column
}

begin
  # List Load Balancers in a specific location of a project
  result = api_instance.list_location_load_balancers(project_id, location, opts)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->list_location_load_balancers: #{e}"
end
```

#### Using the list_location_load_balancers_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<ListLoadBalancers200Response>, Integer, Hash)> list_location_load_balancers_with_http_info(project_id, location, opts)

```ruby
begin
  # List Load Balancers in a specific location of a project
  data, status_code, headers = api_instance.list_location_load_balancers_with_http_info(project_id, location, opts)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <ListLoadBalancers200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->list_location_load_balancers_with_http_info: #{e}"
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

[**ListLoadBalancers200Response**](ListLoadBalancers200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## patch_location_load_balancer

> <GetLoadBalancer200Response> patch_location_load_balancer(project_id, location, load_balancer_name, patch_location_load_balancer_request)

Update a Load Balancer in a specific location of a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::LoadBalancerApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
location = 'eu-central-h1' # String | The Ubicloud location/region
load_balancer_name = 'load_balancer_name_example' # String | Name of the load balancer
patch_location_load_balancer_request = Ubicloud::PatchLocationLoadBalancerRequest.new # PatchLocationLoadBalancerRequest | 

begin
  # Update a Load Balancer in a specific location of a project
  result = api_instance.patch_location_load_balancer(project_id, location, load_balancer_name, patch_location_load_balancer_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->patch_location_load_balancer: #{e}"
end
```

#### Using the patch_location_load_balancer_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetLoadBalancer200Response>, Integer, Hash)> patch_location_load_balancer_with_http_info(project_id, location, load_balancer_name, patch_location_load_balancer_request)

```ruby
begin
  # Update a Load Balancer in a specific location of a project
  data, status_code, headers = api_instance.patch_location_load_balancer_with_http_info(project_id, location, load_balancer_name, patch_location_load_balancer_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetLoadBalancer200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling LoadBalancerApi->patch_location_load_balancer_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **location** | **String** | The Ubicloud location/region |  |
| **load_balancer_name** | **String** | Name of the load balancer |  |
| **patch_location_load_balancer_request** | [**PatchLocationLoadBalancerRequest**](PatchLocationLoadBalancerRequest.md) |  |  |

### Return type

[**GetLoadBalancer200Response**](GetLoadBalancer200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

