=begin
#Clover API

#API for managing resources on Ubicloud

The version of the OpenAPI document: 0.1.0
Contact: support@ubicloud.com
Generated by: https://openapi-generator.tech
Generator version: 7.12.0

=end

require 'cgi'

module Ubicloud
  class VirtualMachineApi
    attr_accessor :api_client

    def initialize(api_client = ApiClient.default)
      @api_client = api_client
    end
    # Create a new VM in a specific location of a project
    # @param project_id [String] ID of the project
    # @param location [String] The Ubicloud location/region
    # @param vm_name [String] Virtual machine name
    # @param create_vm_request [CreateVMRequest] 
    # @param [Hash] opts the optional parameters
    # @return [GetVMDetails200Response]
    def create_vm(project_id, location, vm_name, create_vm_request, opts = {})
      data, _status_code, _headers = create_vm_with_http_info(project_id, location, vm_name, create_vm_request, opts)
      data
    end

    # Create a new VM in a specific location of a project
    # @param project_id [String] ID of the project
    # @param location [String] The Ubicloud location/region
    # @param vm_name [String] Virtual machine name
    # @param create_vm_request [CreateVMRequest] 
    # @param [Hash] opts the optional parameters
    # @return [Array<(GetVMDetails200Response, Integer, Hash)>] GetVMDetails200Response data, response status code and response headers
    def create_vm_with_http_info(project_id, location, vm_name, create_vm_request, opts = {})
      if @api_client.config.debugging
        @api_client.config.logger.debug 'Calling API: VirtualMachineApi.create_vm ...'
      end
      # verify the required parameter 'project_id' is set
      if @api_client.config.client_side_validation && project_id.nil?
        fail ArgumentError, "Missing the required parameter 'project_id' when calling VirtualMachineApi.create_vm"
      end
      pattern = Regexp.new(/^pj[0-9a-hj-km-np-tv-z]{24}$/)
      if @api_client.config.client_side_validation && project_id !~ pattern
        fail ArgumentError, "invalid value for 'project_id' when calling VirtualMachineApi.create_vm, must conform to the pattern #{pattern}."
      end

      # verify the required parameter 'location' is set
      if @api_client.config.client_side_validation && location.nil?
        fail ArgumentError, "Missing the required parameter 'location' when calling VirtualMachineApi.create_vm"
      end
      # verify the required parameter 'vm_name' is set
      if @api_client.config.client_side_validation && vm_name.nil?
        fail ArgumentError, "Missing the required parameter 'vm_name' when calling VirtualMachineApi.create_vm"
      end
      # verify the required parameter 'create_vm_request' is set
      if @api_client.config.client_side_validation && create_vm_request.nil?
        fail ArgumentError, "Missing the required parameter 'create_vm_request' when calling VirtualMachineApi.create_vm"
      end
      # resource path
      local_var_path = '/project/{project_id}/location/{location}/vm/{vm_name}'.sub('{' + 'project_id' + '}', CGI.escape(project_id.to_s)).sub('{' + 'location' + '}', CGI.escape(location.to_s)).sub('{' + 'vm_name' + '}', CGI.escape(vm_name.to_s))

      # query parameters
      query_params = opts[:query_params] || {}

      # header parameters
      header_params = opts[:header_params] || {}
      # HTTP header 'Accept' (if needed)
      header_params['Accept'] = @api_client.select_header_accept(['application/json']) unless header_params['Accept']
      # HTTP header 'Content-Type'
      content_type = @api_client.select_header_content_type(['application/json'])
      if !content_type.nil?
          header_params['Content-Type'] = content_type
      end

      # form parameters
      form_params = opts[:form_params] || {}

      # http body (model)
      post_body = opts[:debug_body] || @api_client.object_to_http_body(create_vm_request)

      # return_type
      return_type = opts[:debug_return_type] || 'GetVMDetails200Response'

      # auth_names
      auth_names = opts[:debug_auth_names] || ['BearerAuth']

      new_options = opts.merge(
        :operation => :"VirtualMachineApi.create_vm",
        :header_params => header_params,
        :query_params => query_params,
        :form_params => form_params,
        :body => post_body,
        :auth_names => auth_names,
        :return_type => return_type
      )

      data, status_code, headers = @api_client.call_api(:POST, local_var_path, new_options)
      if @api_client.config.debugging
        @api_client.config.logger.debug "API called: VirtualMachineApi#create_vm\nData: #{data.inspect}\nStatus code: #{status_code}\nHeaders: #{headers}"
      end
      return data, status_code, headers
    end

    # Delete a specific VM
    # @param project_id [String] ID of the project
    # @param location [String] The Ubicloud location/region
    # @param vm_name [String] Virtual machine name
    # @param [Hash] opts the optional parameters
    # @return [nil]
    def delete_vm(project_id, location, vm_name, opts = {})
      delete_vm_with_http_info(project_id, location, vm_name, opts)
      nil
    end

    # Delete a specific VM
    # @param project_id [String] ID of the project
    # @param location [String] The Ubicloud location/region
    # @param vm_name [String] Virtual machine name
    # @param [Hash] opts the optional parameters
    # @return [Array<(nil, Integer, Hash)>] nil, response status code and response headers
    def delete_vm_with_http_info(project_id, location, vm_name, opts = {})
      if @api_client.config.debugging
        @api_client.config.logger.debug 'Calling API: VirtualMachineApi.delete_vm ...'
      end
      # verify the required parameter 'project_id' is set
      if @api_client.config.client_side_validation && project_id.nil?
        fail ArgumentError, "Missing the required parameter 'project_id' when calling VirtualMachineApi.delete_vm"
      end
      pattern = Regexp.new(/^pj[0-9a-hj-km-np-tv-z]{24}$/)
      if @api_client.config.client_side_validation && project_id !~ pattern
        fail ArgumentError, "invalid value for 'project_id' when calling VirtualMachineApi.delete_vm, must conform to the pattern #{pattern}."
      end

      # verify the required parameter 'location' is set
      if @api_client.config.client_side_validation && location.nil?
        fail ArgumentError, "Missing the required parameter 'location' when calling VirtualMachineApi.delete_vm"
      end
      # verify the required parameter 'vm_name' is set
      if @api_client.config.client_side_validation && vm_name.nil?
        fail ArgumentError, "Missing the required parameter 'vm_name' when calling VirtualMachineApi.delete_vm"
      end
      # resource path
      local_var_path = '/project/{project_id}/location/{location}/vm/{vm_name}'.sub('{' + 'project_id' + '}', CGI.escape(project_id.to_s)).sub('{' + 'location' + '}', CGI.escape(location.to_s)).sub('{' + 'vm_name' + '}', CGI.escape(vm_name.to_s))

      # query parameters
      query_params = opts[:query_params] || {}

      # header parameters
      header_params = opts[:header_params] || {}
      # HTTP header 'Accept' (if needed)
      header_params['Accept'] = @api_client.select_header_accept(['application/json']) unless header_params['Accept']

      # form parameters
      form_params = opts[:form_params] || {}

      # http body (model)
      post_body = opts[:debug_body]

      # return_type
      return_type = opts[:debug_return_type]

      # auth_names
      auth_names = opts[:debug_auth_names] || ['BearerAuth']

      new_options = opts.merge(
        :operation => :"VirtualMachineApi.delete_vm",
        :header_params => header_params,
        :query_params => query_params,
        :form_params => form_params,
        :body => post_body,
        :auth_names => auth_names,
        :return_type => return_type
      )

      data, status_code, headers = @api_client.call_api(:DELETE, local_var_path, new_options)
      if @api_client.config.debugging
        @api_client.config.logger.debug "API called: VirtualMachineApi#delete_vm\nData: #{data.inspect}\nStatus code: #{status_code}\nHeaders: #{headers}"
      end
      return data, status_code, headers
    end

    # Get details of a specific VM in a location
    # @param project_id [String] ID of the project
    # @param location [String] The Ubicloud location/region
    # @param vm_name [String] Virtual machine name
    # @param [Hash] opts the optional parameters
    # @return [GetVMDetails200Response]
    def get_vm_details(project_id, location, vm_name, opts = {})
      data, _status_code, _headers = get_vm_details_with_http_info(project_id, location, vm_name, opts)
      data
    end

    # Get details of a specific VM in a location
    # @param project_id [String] ID of the project
    # @param location [String] The Ubicloud location/region
    # @param vm_name [String] Virtual machine name
    # @param [Hash] opts the optional parameters
    # @return [Array<(GetVMDetails200Response, Integer, Hash)>] GetVMDetails200Response data, response status code and response headers
    def get_vm_details_with_http_info(project_id, location, vm_name, opts = {})
      if @api_client.config.debugging
        @api_client.config.logger.debug 'Calling API: VirtualMachineApi.get_vm_details ...'
      end
      # verify the required parameter 'project_id' is set
      if @api_client.config.client_side_validation && project_id.nil?
        fail ArgumentError, "Missing the required parameter 'project_id' when calling VirtualMachineApi.get_vm_details"
      end
      pattern = Regexp.new(/^pj[0-9a-hj-km-np-tv-z]{24}$/)
      if @api_client.config.client_side_validation && project_id !~ pattern
        fail ArgumentError, "invalid value for 'project_id' when calling VirtualMachineApi.get_vm_details, must conform to the pattern #{pattern}."
      end

      # verify the required parameter 'location' is set
      if @api_client.config.client_side_validation && location.nil?
        fail ArgumentError, "Missing the required parameter 'location' when calling VirtualMachineApi.get_vm_details"
      end
      # verify the required parameter 'vm_name' is set
      if @api_client.config.client_side_validation && vm_name.nil?
        fail ArgumentError, "Missing the required parameter 'vm_name' when calling VirtualMachineApi.get_vm_details"
      end
      # resource path
      local_var_path = '/project/{project_id}/location/{location}/vm/{vm_name}'.sub('{' + 'project_id' + '}', CGI.escape(project_id.to_s)).sub('{' + 'location' + '}', CGI.escape(location.to_s)).sub('{' + 'vm_name' + '}', CGI.escape(vm_name.to_s))

      # query parameters
      query_params = opts[:query_params] || {}

      # header parameters
      header_params = opts[:header_params] || {}
      # HTTP header 'Accept' (if needed)
      header_params['Accept'] = @api_client.select_header_accept(['application/json']) unless header_params['Accept']

      # form parameters
      form_params = opts[:form_params] || {}

      # http body (model)
      post_body = opts[:debug_body]

      # return_type
      return_type = opts[:debug_return_type] || 'GetVMDetails200Response'

      # auth_names
      auth_names = opts[:debug_auth_names] || ['BearerAuth']

      new_options = opts.merge(
        :operation => :"VirtualMachineApi.get_vm_details",
        :header_params => header_params,
        :query_params => query_params,
        :form_params => form_params,
        :body => post_body,
        :auth_names => auth_names,
        :return_type => return_type
      )

      data, status_code, headers = @api_client.call_api(:GET, local_var_path, new_options)
      if @api_client.config.debugging
        @api_client.config.logger.debug "API called: VirtualMachineApi#get_vm_details\nData: #{data.inspect}\nStatus code: #{status_code}\nHeaders: #{headers}"
      end
      return data, status_code, headers
    end

    # List VMs in a specific location of a project
    # @param location [String] The Ubicloud location/region
    # @param project_id [String] ID of the project
    # @param [Hash] opts the optional parameters
    # @option opts [String] :start_after Pagination - Start after
    # @option opts [Integer] :page_size Pagination - Page size (default to 10)
    # @option opts [String] :order_column Pagination - Order column (default to 'id')
    # @return [ListLocationVMs200Response]
    def list_location_vms(location, project_id, opts = {})
      data, _status_code, _headers = list_location_vms_with_http_info(location, project_id, opts)
      data
    end

    # List VMs in a specific location of a project
    # @param location [String] The Ubicloud location/region
    # @param project_id [String] ID of the project
    # @param [Hash] opts the optional parameters
    # @option opts [String] :start_after Pagination - Start after
    # @option opts [Integer] :page_size Pagination - Page size (default to 10)
    # @option opts [String] :order_column Pagination - Order column (default to 'id')
    # @return [Array<(ListLocationVMs200Response, Integer, Hash)>] ListLocationVMs200Response data, response status code and response headers
    def list_location_vms_with_http_info(location, project_id, opts = {})
      if @api_client.config.debugging
        @api_client.config.logger.debug 'Calling API: VirtualMachineApi.list_location_vms ...'
      end
      # verify the required parameter 'location' is set
      if @api_client.config.client_side_validation && location.nil?
        fail ArgumentError, "Missing the required parameter 'location' when calling VirtualMachineApi.list_location_vms"
      end
      # verify the required parameter 'project_id' is set
      if @api_client.config.client_side_validation && project_id.nil?
        fail ArgumentError, "Missing the required parameter 'project_id' when calling VirtualMachineApi.list_location_vms"
      end
      pattern = Regexp.new(/^pj[0-9a-hj-km-np-tv-z]{24}$/)
      if @api_client.config.client_side_validation && project_id !~ pattern
        fail ArgumentError, "invalid value for 'project_id' when calling VirtualMachineApi.list_location_vms, must conform to the pattern #{pattern}."
      end

      # resource path
      local_var_path = '/project/{project_id}/location/{location}/vm'.sub('{' + 'location' + '}', CGI.escape(location.to_s)).sub('{' + 'project_id' + '}', CGI.escape(project_id.to_s))

      # query parameters
      query_params = opts[:query_params] || {}
      query_params[:'start_after'] = opts[:'start_after'] if !opts[:'start_after'].nil?
      query_params[:'page_size'] = opts[:'page_size'] if !opts[:'page_size'].nil?
      query_params[:'order_column'] = opts[:'order_column'] if !opts[:'order_column'].nil?

      # header parameters
      header_params = opts[:header_params] || {}
      # HTTP header 'Accept' (if needed)
      header_params['Accept'] = @api_client.select_header_accept(['application/json']) unless header_params['Accept']

      # form parameters
      form_params = opts[:form_params] || {}

      # http body (model)
      post_body = opts[:debug_body]

      # return_type
      return_type = opts[:debug_return_type] || 'ListLocationVMs200Response'

      # auth_names
      auth_names = opts[:debug_auth_names] || ['BearerAuth']

      new_options = opts.merge(
        :operation => :"VirtualMachineApi.list_location_vms",
        :header_params => header_params,
        :query_params => query_params,
        :form_params => form_params,
        :body => post_body,
        :auth_names => auth_names,
        :return_type => return_type
      )

      data, status_code, headers = @api_client.call_api(:GET, local_var_path, new_options)
      if @api_client.config.debugging
        @api_client.config.logger.debug "API called: VirtualMachineApi#list_location_vms\nData: #{data.inspect}\nStatus code: #{status_code}\nHeaders: #{headers}"
      end
      return data, status_code, headers
    end

    # List all VMs created under the given project ID and visible to logged in user
    # @param project_id [String] ID of the project
    # @param [Hash] opts the optional parameters
    # @option opts [String] :start_after Pagination - Start after
    # @option opts [Integer] :page_size Pagination - Page size (default to 10)
    # @option opts [String] :order_column Pagination - Order column (default to 'id')
    # @return [ListLocationVMs200Response]
    def list_project_vms(project_id, opts = {})
      data, _status_code, _headers = list_project_vms_with_http_info(project_id, opts)
      data
    end

    # List all VMs created under the given project ID and visible to logged in user
    # @param project_id [String] ID of the project
    # @param [Hash] opts the optional parameters
    # @option opts [String] :start_after Pagination - Start after
    # @option opts [Integer] :page_size Pagination - Page size (default to 10)
    # @option opts [String] :order_column Pagination - Order column (default to 'id')
    # @return [Array<(ListLocationVMs200Response, Integer, Hash)>] ListLocationVMs200Response data, response status code and response headers
    def list_project_vms_with_http_info(project_id, opts = {})
      if @api_client.config.debugging
        @api_client.config.logger.debug 'Calling API: VirtualMachineApi.list_project_vms ...'
      end
      # verify the required parameter 'project_id' is set
      if @api_client.config.client_side_validation && project_id.nil?
        fail ArgumentError, "Missing the required parameter 'project_id' when calling VirtualMachineApi.list_project_vms"
      end
      pattern = Regexp.new(/^pj[0-9a-hj-km-np-tv-z]{24}$/)
      if @api_client.config.client_side_validation && project_id !~ pattern
        fail ArgumentError, "invalid value for 'project_id' when calling VirtualMachineApi.list_project_vms, must conform to the pattern #{pattern}."
      end

      # resource path
      local_var_path = '/project/{project_id}/vm'.sub('{' + 'project_id' + '}', CGI.escape(project_id.to_s))

      # query parameters
      query_params = opts[:query_params] || {}
      query_params[:'start_after'] = opts[:'start_after'] if !opts[:'start_after'].nil?
      query_params[:'page_size'] = opts[:'page_size'] if !opts[:'page_size'].nil?
      query_params[:'order_column'] = opts[:'order_column'] if !opts[:'order_column'].nil?

      # header parameters
      header_params = opts[:header_params] || {}
      # HTTP header 'Accept' (if needed)
      header_params['Accept'] = @api_client.select_header_accept(['application/json']) unless header_params['Accept']

      # form parameters
      form_params = opts[:form_params] || {}

      # http body (model)
      post_body = opts[:debug_body]

      # return_type
      return_type = opts[:debug_return_type] || 'ListLocationVMs200Response'

      # auth_names
      auth_names = opts[:debug_auth_names] || ['BearerAuth']

      new_options = opts.merge(
        :operation => :"VirtualMachineApi.list_project_vms",
        :header_params => header_params,
        :query_params => query_params,
        :form_params => form_params,
        :body => post_body,
        :auth_names => auth_names,
        :return_type => return_type
      )

      data, status_code, headers = @api_client.call_api(:GET, local_var_path, new_options)
      if @api_client.config.debugging
        @api_client.config.logger.debug "API called: VirtualMachineApi#list_project_vms\nData: #{data.inspect}\nStatus code: #{status_code}\nHeaders: #{headers}"
      end
      return data, status_code, headers
    end

    # Restart a specific VM
    # @param project_id [String] ID of the project
    # @param location [String] The Ubicloud location/region
    # @param vm_name [String] Virtual machine name
    # @param [Hash] opts the optional parameters
    # @return [GetVMDetails200Response]
    def restart_vm(project_id, location, vm_name, opts = {})
      data, _status_code, _headers = restart_vm_with_http_info(project_id, location, vm_name, opts)
      data
    end

    # Restart a specific VM
    # @param project_id [String] ID of the project
    # @param location [String] The Ubicloud location/region
    # @param vm_name [String] Virtual machine name
    # @param [Hash] opts the optional parameters
    # @return [Array<(GetVMDetails200Response, Integer, Hash)>] GetVMDetails200Response data, response status code and response headers
    def restart_vm_with_http_info(project_id, location, vm_name, opts = {})
      if @api_client.config.debugging
        @api_client.config.logger.debug 'Calling API: VirtualMachineApi.restart_vm ...'
      end
      # verify the required parameter 'project_id' is set
      if @api_client.config.client_side_validation && project_id.nil?
        fail ArgumentError, "Missing the required parameter 'project_id' when calling VirtualMachineApi.restart_vm"
      end
      pattern = Regexp.new(/^pj[0-9a-hj-km-np-tv-z]{24}$/)
      if @api_client.config.client_side_validation && project_id !~ pattern
        fail ArgumentError, "invalid value for 'project_id' when calling VirtualMachineApi.restart_vm, must conform to the pattern #{pattern}."
      end

      # verify the required parameter 'location' is set
      if @api_client.config.client_side_validation && location.nil?
        fail ArgumentError, "Missing the required parameter 'location' when calling VirtualMachineApi.restart_vm"
      end
      # verify the required parameter 'vm_name' is set
      if @api_client.config.client_side_validation && vm_name.nil?
        fail ArgumentError, "Missing the required parameter 'vm_name' when calling VirtualMachineApi.restart_vm"
      end
      # resource path
      local_var_path = '/project/{project_id}/location/{location}/vm/{vm_name}/restart'.sub('{' + 'project_id' + '}', CGI.escape(project_id.to_s)).sub('{' + 'location' + '}', CGI.escape(location.to_s)).sub('{' + 'vm_name' + '}', CGI.escape(vm_name.to_s))

      # query parameters
      query_params = opts[:query_params] || {}

      # header parameters
      header_params = opts[:header_params] || {}
      # HTTP header 'Accept' (if needed)
      header_params['Accept'] = @api_client.select_header_accept(['application/json']) unless header_params['Accept']

      # form parameters
      form_params = opts[:form_params] || {}

      # http body (model)
      post_body = opts[:debug_body]

      # return_type
      return_type = opts[:debug_return_type] || 'GetVMDetails200Response'

      # auth_names
      auth_names = opts[:debug_auth_names] || ['BearerAuth']

      new_options = opts.merge(
        :operation => :"VirtualMachineApi.restart_vm",
        :header_params => header_params,
        :query_params => query_params,
        :form_params => form_params,
        :body => post_body,
        :auth_names => auth_names,
        :return_type => return_type
      )

      data, status_code, headers = @api_client.call_api(:POST, local_var_path, new_options)
      if @api_client.config.debugging
        @api_client.config.logger.debug "API called: VirtualMachineApi#restart_vm\nData: #{data.inspect}\nStatus code: #{status_code}\nHeaders: #{headers}"
      end
      return data, status_code, headers
    end
  end
end
