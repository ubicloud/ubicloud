# frozen_string_literal: true

# Based on Pliny: https://github.com/interagent/pliny/blob/master/lib/template/lib/serializers/base.rb
#
# Copyright (c) 2014 Brandur Leach and Pedro Belo
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.

module Serializers
  class Base
    def self.serialize(object, options = {})
      return if object.nil?

      if object.respond_to?(:map) && !object.is_a?(Hash)
        object.map { |item| serialize_internal(item, options) }
      else
        serialize_internal(object, options)
      end
    end

    def self.serialize_internal(object, options = {})
      raise NoMethodError
    end
  end
end
