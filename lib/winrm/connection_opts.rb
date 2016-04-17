# -*- encoding: utf-8 -*-
#
# Copyright 2016 Shawn Neal <sneal@sneal.net>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'securerandom'

module WinRM
  # WinRM connection options, provides defaults and validation.
  class ConnectionOpts < Hash
    DEFAULT_OPERATION_TIMEOUT = 60
    DEFAULT_RECEIVE_TIMEOUT = DEFAULT_OPERATION_TIMEOUT + 10
    DEFAULT_MAX_ENV_SIZE = 153600
    DEFAULT_LOCALE = 'en-US'
    DEFAULT_RETRY_DELAY = 10
    DEFAULT_RETRY_LIMIT = 3
    DEFAULT_MAX_COMMANDS = 1480 # TODO: interrogate remote OS version

    def self.create_with_defaults(overrides)
      config = default.merge(overrides)
      config = ensure_receive_timeout_is_greater_than_operation_timeout(config)
      config.validate
      config
    end

    def validate
      validate_required_fields
      validate_data_types
    end

    private

    def validate_required_fields
      fail 'endpoint is a required option' unless self[:endpoint]
      fail 'user is a required option' unless self[:user]
      fail 'password is a required option' unless self[:password]
    end

    def validate_data_types
      validate_fixnum(:retry_limit)
      validate_fixnum(:retry_delay)
      validate_fixnum(:max_envelope_size)
      validate_fixnum(:max_commands)
      validate_fixnum(:operation_timeout)
      validate_fixnum(:receive_timeout, self[:operation_timeout])
    end

    def validate_fixnum(key, min = 0)
      value = self[key]
      fail "#{key} must be a Fixnum" unless value && value.is_a?(Fixnum)
      fail "#{key} must be greater than #{min}" unless value > min
    end

    def self.ensure_receive_timeout_is_greater_than_operation_timeout(config)
      if config[:receive_timeout] < config[:operation_timeout]
        config[:receive_timeout] = config[:operation_timeout] + 10
      end
      config
    end

    def self.default
      config = ConnectionOpts.new
      config[:session_id] = SecureRandom.uuid.to_s.upcase
      config[:transport] = :negotiate
      config[:locale] = DEFAULT_LOCALE
      config[:max_envelope_size] = DEFAULT_MAX_ENV_SIZE
      config[:max_commands] = DEFAULT_MAX_COMMANDS
      config[:operation_timeout] = DEFAULT_OPERATION_TIMEOUT
      config[:receive_timeout] = DEFAULT_RECEIVE_TIMEOUT
      config[:retry_delay] = DEFAULT_RETRY_DELAY
      config[:retry_limit] = DEFAULT_RETRY_LIMIT
      config
    end
  end
end
