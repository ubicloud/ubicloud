# Ubicloud::ProjectApi

All URIs are relative to *https://api.ubicloud.com*

| Method | HTTP request | Description |
| ------ | ------------ | ----------- |
| [**create_project**](ProjectApi.md#create_project) | **POST** /project | Create a new project |
| [**delete_project**](ProjectApi.md#delete_project) | **DELETE** /project/{project_id} | Delete a project |
| [**get_object_info**](ProjectApi.md#get_object_info) | **GET** /project/{project_id}/object-info/{object_id} | Return information on object type, location, and name |
| [**get_project**](ProjectApi.md#get_project) | **GET** /project/{project_id} | Retrieve a project |
| [**list_projects**](ProjectApi.md#list_projects) | **GET** /project | List all projects visible to the logged in user. |


## create_project

> <Project> create_project(create_project_request)

Create a new project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::ProjectApi.new
create_project_request = Ubicloud::CreateProjectRequest.new({name: 'my-project-name'}) # CreateProjectRequest | 

begin
  # Create a new project
  result = api_instance.create_project(create_project_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling ProjectApi->create_project: #{e}"
end
```

#### Using the create_project_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<Project>, Integer, Hash)> create_project_with_http_info(create_project_request)

```ruby
begin
  # Create a new project
  data, status_code, headers = api_instance.create_project_with_http_info(create_project_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <Project>
rescue Ubicloud::ApiError => e
  puts "Error when calling ProjectApi->create_project_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **create_project_request** | [**CreateProjectRequest**](CreateProjectRequest.md) |  |  |

### Return type

[**Project**](Project.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json


## delete_project

> delete_project(project_id)

Delete a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::ProjectApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project

begin
  # Delete a project
  api_instance.delete_project(project_id)
rescue Ubicloud::ApiError => e
  puts "Error when calling ProjectApi->delete_project: #{e}"
end
```

#### Using the delete_project_with_http_info variant

This returns an Array which contains the response data (`nil` in this case), status code and headers.

> <Array(nil, Integer, Hash)> delete_project_with_http_info(project_id)

```ruby
begin
  # Delete a project
  data, status_code, headers = api_instance.delete_project_with_http_info(project_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => nil
rescue Ubicloud::ApiError => e
  puts "Error when calling ProjectApi->delete_project_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |

### Return type

nil (empty response body)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## get_object_info

> <GetObjectInfo200Response> get_object_info(project_id, object_id)

Return information on object type, location, and name

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::ProjectApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project
object_id = 'fwkkmx0f2vke4h36nk9cm8v8q0' # String | ID of a supported object

begin
  # Return information on object type, location, and name
  result = api_instance.get_object_info(project_id, object_id)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling ProjectApi->get_object_info: #{e}"
end
```

#### Using the get_object_info_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<GetObjectInfo200Response>, Integer, Hash)> get_object_info_with_http_info(project_id, object_id)

```ruby
begin
  # Return information on object type, location, and name
  data, status_code, headers = api_instance.get_object_info_with_http_info(project_id, object_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <GetObjectInfo200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling ProjectApi->get_object_info_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |
| **object_id** | **String** | ID of a supported object |  |

### Return type

[**GetObjectInfo200Response**](GetObjectInfo200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## get_project

> <Project> get_project(project_id)

Retrieve a project

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::ProjectApi.new
project_id = 'pjkkmx0f2vke4h36nk9cm8v8q0' # String | ID of the project

begin
  # Retrieve a project
  result = api_instance.get_project(project_id)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling ProjectApi->get_project: #{e}"
end
```

#### Using the get_project_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<Project>, Integer, Hash)> get_project_with_http_info(project_id)

```ruby
begin
  # Retrieve a project
  data, status_code, headers = api_instance.get_project_with_http_info(project_id)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <Project>
rescue Ubicloud::ApiError => e
  puts "Error when calling ProjectApi->get_project_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **project_id** | **String** | ID of the project |  |

### Return type

[**Project**](Project.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json


## list_projects

> <ListProjects200Response> list_projects(opts)

List all projects visible to the logged in user.

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'
# setup authorization
Ubicloud.configure do |config|
  # Configure Bearer authorization (JWT): BearerAuth
  config.access_token = 'YOUR_BEARER_TOKEN'
end

api_instance = Ubicloud::ProjectApi.new
opts = {
  start_after: 'start_after_example', # String | Pagination - Start after
  page_size: 56, # Integer | Pagination - Page size
  order_column: 'order_column_example' # String | Pagination - Order column
}

begin
  # List all projects visible to the logged in user.
  result = api_instance.list_projects(opts)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling ProjectApi->list_projects: #{e}"
end
```

#### Using the list_projects_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<ListProjects200Response>, Integer, Hash)> list_projects_with_http_info(opts)

```ruby
begin
  # List all projects visible to the logged in user.
  data, status_code, headers = api_instance.list_projects_with_http_info(opts)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <ListProjects200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling ProjectApi->list_projects_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **start_after** | **String** | Pagination - Start after | [optional] |
| **page_size** | **Integer** | Pagination - Page size | [optional][default to 10] |
| **order_column** | **String** | Pagination - Order column | [optional][default to &#39;id&#39;] |

### Return type

[**ListProjects200Response**](ListProjects200Response.md)

### Authorization

[BearerAuth](../README.md#BearerAuth)

### HTTP request headers

- **Content-Type**: Not defined
- **Accept**: application/json

