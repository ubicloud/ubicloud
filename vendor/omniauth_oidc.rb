# frozen_string_literal: true

# This code is originally derived from omniauth_openid_connect, which
# is distributed under the following license:
#
# Copyright (c) 2014 John Bohn
#
# MIT License
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require 'base64'
require 'omniauth'

module OmniAuth
  module Strategies
    class Oidc
      include OmniAuth::Strategy

      class MissingCodeError < RuntimeError; end

      option :name
      option :client_options
      option :issuer
      # option :prompt, nil # [:none, :login, :consent, :select_account]
      # option :hd, nil
      # option :uid_field, 'sub'

      def uid
        # user_info.raw_attributes[options.uid_field.to_sym] ||
        @user_info["sub"]
      end

      def params
        request.params
      end

      attr_reader :access_token, :user_info

      info { @user_info }
      extra { {} }

      credentials do
        {
          id_token: @id_token,
          token: @access_token,
          expires_in: @access_token_expires_in,
        }
      end

      def request_phase
        nonce = session['omniauth.nonce'] = Base64.urlsafe_encode64(SecureRandom.bytes(32))
        state = session['omniauth.state'] = Base64.urlsafe_encode64(SecureRandom.bytes(32))

        opts = client_options
        params = {
          redirect_uri:,
          response_type: "code",
          scope: "openid email",
          client_id: opts[:identifier],
          # prompt: options.prompt,
          # hd: options.hd,
          nonce:,
          state:
        }

        redirect "#{base_url_for(:authorization_endpoint)}?#{query_string_for(params)}"
      end

      def callback_phase
        if (error = params['error_reason'] || params['error'])
          error_description = params['error_description'] || params['error_reason']
          raise CallbackError, error: params['error'], reason: error_description, uri: params['error_uri']
        end

        expected_state = session.delete('omniauth.state')
        raise CallbackError, error: :csrf_detected, reason: "Invalid 'state' parameter" if expected_state.nil?  || params['state'] != expected_state

        unless (code = params["code"])
          fail!(:missing_code, MissingCodeError.new(params['error']))
          return
        end

        opts = client_options
        response = Excon.post(
          base_url_for(:token_endpoint),
          headers: {
            'Authorization' => "Basic #{Base64.strict_encode64([CGI.escape(opts[:identifier]), CGI.escape(opts[:secret])].join(':'))}",
            "Content-Type" => "application/x-www-form-urlencoded",
            "Accept" => "application/json",
          },
          body: query_string_for({
            "grant_type" => "authorization_code",
            "code" => params["code"],
            "redirect_uri" => redirect_uri
          }.compact),
          expects: [200, 201]
        )

        token_hash = JSON.parse(response.body)
        token_type = token_hash['token_type']&.downcase
        unless token_type == "bearer"
          fail!(:unexpected_token_type, RuntimeError.new("Unexpected token type returned by OIDC token request: #{token_type}"))
          return
        end

        @access_token = token_hash["access_token"]
        @access_token_expires_in = token_hash["expires_in"]

        if (@id_token = token_hash["id_token"])
          token = JWT.decode(@id_token, nil, false)
          token = token[0] if token.is_a?(Array)
          if token.is_a?(Hash)
            nonce = session.delete('omniauth.nonce')
            aud = token["aud"]
            aud = [aud] if aud.is_a?(String)
            if token["iss"] != options.issuer || !aud.include?(client_options.identifier) || token["nonce"] != nonce
              fail!(:unable_to_verify_id_token, RuntimeError.new("Unable to verify id token"))
              return
            end
            user_info = token.slice("sub", "email").compact
            # The id_token must contain sub to be compliant with OpenID Connect.
            # It is not required to provide email.  If it doesn't, we'll need to make a request
            # to the userinfo endpoint.
            if user_info.length == 2
              if (email_verified = token["email_verified"])
                user_info["email_verified"] = token["email_verified"]
              end
              @user_info = user_info
            end
          end
        end

        unless @user_info
          response = Excon.get(
            base_url_for(:userinfo_endpoint),
            headers: {'Authorization' => "Bearer #{@access_token}", "Accept" => "application/json"},
            expects: 200
          )
          @user_info = JSON.parse(response.body)
        end

        super
      rescue CallbackError => e
        fail!(e.error, e)
      rescue ::Excon::Error => e
        fail!(:invalid_response_status, e)
      rescue ::JWT::DecodeError => e
        fail!(:jwt_error, e)
      rescue ::Errno::ETIMEDOUT => e
        fail!(:timeout, e)
      rescue ::SocketError => e
        fail!(:failed_to_connect, e)
      end

      def other_phase
        call_app!
      end

      private

      def base_url_for(endpoint_key)
        opts = client_options
        "#{opts[:scheme]}://#{opts[:host]}:#{opts[:port]}#{opts[endpoint_key]}"
      end

      def query_string_for(params)
        params.map do |k, v|
          "#{k}=#{CGI.escape(v).gsub('+', '%20')}"
        end.join("&")
      end

      def client_options
        options.client_options
      end

      def redirect_uri
        if (redirect_uri = params['redirect_uri'])
          "#{ client_options.redirect_uri }?redirect_uri=#{ CGI.escape(redirect_uri) }"
        else
          client_options.redirect_uri
        end
      end

      class CallbackError < StandardError
        attr_accessor :error, :error_reason, :error_uri

        def initialize(data)
          super
          self.error = data[:error]
          self.error_reason = data[:reason]
          self.error_uri = data[:uri]
        end

        def message
          [error, error_reason, error_uri].compact.join(' | ')
        end
      end
    end
  end
end
