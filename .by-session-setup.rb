# frozen_string_literal: true

require "bundler/setup"
Bundler.require(:default)
Bundler.require(:test)

<<END.split.each { |f| require f }
digest/sha2
open-uri
unicode_normalize/normalize
unicode_normalize/tables
enc/trans/single_byte
enc/trans/utf_16_32
enc/iso_8859_1
enc/utf_16be
enc/utf_16le
rubygems/openssl
rubygems/package
rubygems/security
ripper
coderay/scanners
coderay/scanners/ruby
coderay/scanners/ruby/patterns
coderay/scanners/ruby/string_state
diff/lcs
webmock/rspec
tilt/erubi
tilt/string
sequel/adapters/postgres
sequel/connection_pool/timed_queue
capybara/dsl
capybara/rspec
mail/network/delivery_methods/logger_delivery
mail/network/delivery_methods/test_mailer
mail/smtp_envelope
rack/head
rack/files
rack/multipart
rack/body_proxy
rspec/mocks
rspec/expectations
rspec/support/fuzzy_matcher
rspec/support/mutex
rspec/support/object_formatter
rspec/core/example_status_persister
rspec/core/formatters/base_formatter
rspec/core/formatters/base_text_formatter
rspec/core/formatters/documentation_formatter
rspec/core/formatters/profile_formatter
rspec/core/mocking_adapters/rspec
rspec/core/profiler
rspec/matchers/built_in/eq
rspec/matchers/built_in/start_or_end_with
rspec/mocks/any_instance
rspec/mocks/any_instance/chain
rspec/mocks/any_instance/error_generator
rspec/mocks/any_instance/expect_chain_chain
rspec/mocks/any_instance/expectation_chain
rspec/mocks/any_instance/message_chains
rspec/mocks/any_instance/proxy
rspec/mocks/any_instance/recorder
rspec/mocks/any_instance/stub_chain
rspec/mocks/any_instance/stub_chain_chain
rspec/mocks/marshal_extension
rspec/mocks/matchers/expectation_customization
rspec/mocks/matchers/receive
rspec/core/formatters/progress_formatter
rspec/matchers/built_in/all
rspec/matchers/built_in/be
rspec/matchers/built_in/be_instance_of
rspec/matchers/built_in/be_kind_of
rspec/matchers/built_in/be_within
rspec/matchers/built_in/change
rspec/matchers/built_in/contain_exactly
rspec/matchers/built_in/count_expectation
rspec/matchers/built_in/equal
rspec/matchers/built_in/exist
rspec/matchers/built_in/has
rspec/matchers/built_in/include
rspec/matchers/built_in/match
rspec/matchers/built_in/output
rspec/matchers/built_in/raise_error
rspec/matchers/built_in/yield
rspec/mocks/matchers/receive_message_chain
rspec/mocks/matchers/receive_messages
rspec/mocks/message_chain
rspec/support/differ
rspec/support/hunk_generator
rspec/support/source
mail/elements/address
mail/elements/address_list
mail/elements/content_disposition_element
mail/elements/content_transfer_encoding_element
mail/elements/content_type_element
mail/elements/message_ids_element
mail/elements/mime_version_element
mail/parsers/address_lists_parser
mail/parsers/content_disposition_parser
mail/parsers/content_transfer_encoding_parser
mail/parsers/content_type_parser
mail/parsers/message_ids_parser
mail/parsers/mime_version_parser
omniauth/builder
aws-sdk-s3/client
aws-sdk-s3/client_api
aws-sdk-s3/customizations/errors
aws-sdk-s3/customizations/types/list_object_versions_output
aws-sdk-s3/customizations/types/permanent_redirect
aws-sdk-s3/errors
aws-sdk-s3/plugins/accelerate
aws-sdk-s3/plugins/access_grants
aws-sdk-s3/plugins/arn
aws-sdk-s3/plugins/bucket_dns
aws-sdk-s3/plugins/bucket_name_restrictions
aws-sdk-s3/plugins/dualstack
aws-sdk-s3/plugins/endpoints
aws-sdk-s3/plugins/expect_100_continue
aws-sdk-s3/plugins/express_session_auth
aws-sdk-s3/plugins/get_bucket_location_fix
aws-sdk-s3/plugins/http_200_errors
aws-sdk-s3/plugins/iad_regional_endpoint
aws-sdk-s3/plugins/location_constraint
aws-sdk-s3/plugins/md5s
aws-sdk-s3/plugins/redirects
aws-sdk-s3/plugins/s3_host_id
aws-sdk-s3/plugins/s3_signer
aws-sdk-s3/plugins/sse_cpk
aws-sdk-s3/plugins/streaming_retry
aws-sdk-s3/plugins/url_encoded_keys
aws-sdk-s3/presigner
aws-sdk-s3/types
aws-sdk-core/rest/response/headers
aws-sdk-core/rest/response/parser
aws-sdk-core/rest/response/status_code
aws-sdk-core/structure
aws-sdk-core/telemetry
aws-sdk-core/telemetry/base
aws-sdk-core/telemetry/no_op
aws-sdk-core/telemetry/otel
aws-sdk-core/telemetry/span_kind
aws-sdk-core/telemetry/span_status
aws-sdk-core/xml
aws-sdk-core/xml/builder
aws-sdk-core/xml/default_list
aws-sdk-core/xml/default_map
aws-sdk-core/xml/doc_builder
aws-sdk-core/xml/error_handler
aws-sdk-core/xml/parser
aws-sdk-core/xml/parser/frame
aws-sdk-core/xml/parser/nokogiri_engine
aws-sdk-core/xml/parser/parsing_error
aws-sdk-core/xml/parser/stack
argon2/kdf/ffi
webauthn/fake_client
END

<<END.split.each { |f| require "sequel/extensions/#{f}" }
date_arithmetic
index_caching
pg_array
pg_auto_parameterize
pg_auto_parameterize_in_array
pg_enum
pg_json
pg_json_ops
pg_range
pg_range_ops
pg_schema_caching
pg_timestamptz
END

<<END.split.each { |f| require "sequel/plugins/#{f}" }
association_dependencies
auto_validations
column_encryption
defaults_setter
insert_conflict
inspect_pk
many_through_many
pg_auto_constraint_validations
pg_auto_validate_enums
pg_eager_any_typed_array
require_valid_schema
serialization
singular_table_names
static_cache
static_cache_cache
subclasses
subset_static_cache
validation_helpers
END

<<END.split.each { |f| require "roda/plugins/#{f}" }
Integer_matcher_max
_base64
_before_hook
_optimized_matching
all_verbs
assets
autoload_hash_branches
caching
common_logger
content_security_policy
conditional_sessions
custom_block_results
default_headers
direct_call
disallow_file_uploads
error_handler
flash
h
hash_branch_view_subdir
hash_branches
host_routing
hooks
invalid_request_body
json
json_parser
not_found
part
public
render
render_coverage
request_headers
route_csrf
run_handler
sessions
status_handler
typecast_params
typecast_params_sized_integers
view_options
rodauth
END

<<END.split.each { |f| require "rodauth/features/#{f}" }
active_sessions
argon2
base
change_login
change_password
change_password_notify
close_account
confirm_password
create_account
disallow_common_passwords
disallow_password_reuse
email_base
json
jwt
lockout
login
login_password_requirements_base
logout
omniauth
omniauth_base
otp
password_grace_period
recovery_codes
remember
reset_password
two_factor_base
verify_account
verify_login_change
webauthn
END

<<END.split.each { |f| require "rodish/plugins/#{f}" }
_context_sensitive_help
_wrap
help_examples
help_option_values
help_order
post_commands
skip_option_parsing
END

lf = $LOADED_FEATURES.dup
at_exit do
  loaded_features = $LOADED_FEATURES - lf
  dir = __dir__
  loaded_features.reject! { it.start_with?(dir) }

  unless loaded_features.empty?
    load_paths = $LOAD_PATH.sort_by { |path| -path.length }
    loaded_features.map! do |f|
      f = f.delete_suffix(".rb")
      catch(:fixed) do
        load_paths.each do |dir|
          if f.start_with?(dir)
            dir += "/" unless dir.end_with?("/")
            throw :fixed, f.delete_prefix(dir)
          end
        end
        f
      end
    end

    puts "Missed preloading, update .by-session-setup.rb to load:"
    puts loaded_features.sort
  end
end
