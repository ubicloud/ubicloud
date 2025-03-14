# Ubicloud::LoginApi

All URIs are relative to *https://api.ubicloud.com*

| Method | HTTP request | Description |
| ------ | ------------ | ----------- |
| [**login**](LoginApi.md#login) | **POST** /login | Login with user information |


## login

> <Login200Response> login(login_request)

Login with user information

### Examples

```ruby
require 'time'
require 'ubicloud-sdk'

api_instance = Ubicloud::LoginApi.new
login_request = Ubicloud::LoginRequest.new({login: 'user@mail.com', password: 'password'}) # LoginRequest | 

begin
  # Login with user information
  result = api_instance.login(login_request)
  p result
rescue Ubicloud::ApiError => e
  puts "Error when calling LoginApi->login: #{e}"
end
```

#### Using the login_with_http_info variant

This returns an Array which contains the response data, status code and headers.

> <Array(<Login200Response>, Integer, Hash)> login_with_http_info(login_request)

```ruby
begin
  # Login with user information
  data, status_code, headers = api_instance.login_with_http_info(login_request)
  p status_code # => 2xx
  p headers # => { ... }
  p data # => <Login200Response>
rescue Ubicloud::ApiError => e
  puts "Error when calling LoginApi->login_with_http_info: #{e}"
end
```

### Parameters

| Name | Type | Description | Notes |
| ---- | ---- | ----------- | ----- |
| **login_request** | [**LoginRequest**](LoginRequest.md) |  |  |

### Return type

[**Login200Response**](Login200Response.md)

### Authorization

No authorization required

### HTTP request headers

- **Content-Type**: application/json
- **Accept**: application/json

