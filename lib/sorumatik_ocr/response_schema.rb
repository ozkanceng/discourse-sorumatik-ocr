# frozen_string_literal: true

require "json"

module SorumatikOcr
  # Client-supplied JSON schema for structured output, forwarded to Gemini as
  # `generationConfig.responseJsonSchema`. Only the JSON Schema keywords the
  # Gemini API supports are kept (anything else, e.g. `pattern`, would get the
  # request rejected), and size and depth are capped so the schema cannot be
  # used to inflate requests.
  module ResponseSchema
    MAX_BYTES = 32_000
    MAX_DEPTH = 24
    MAX_NODES = 2_000
    SUPPORTED_KEYS = %w[
      $id $defs $ref $anchor type format title description enum items prefixItems
      minItems maxItems minimum maximum anyOf oneOf properties additionalProperties
      required propertyOrdering
    ].freeze
    # Keywords whose value is a map of name => sub-schema.
    SCHEMA_MAPS = %w[$defs properties].freeze
    # Keywords whose value is one sub-schema or a list of sub-schemas.
    SCHEMA_VALUES = %w[items additionalProperties].freeze
    SCHEMA_LISTS = %w[anyOf oneOf prefixItems].freeze

    class Invalid < StandardError; end

    module_function

    # Returns the cleaned schema Hash, nil when none was sent; raises Invalid.
    def sanitize(raw)
      return nil if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)

      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      raw = JSON.parse(raw) if raw.is_a?(String)
      raise Invalid, "schema must be an object" unless raw.is_a?(Hash)
      raise Invalid, "schema too large" if JSON.generate(raw).bytesize > MAX_BYTES

      counter = { nodes: 0 }
      clean_schema(raw, 0, counter)
    rescue JSON::ParserError
      raise Invalid, "schema is not valid JSON"
    end

    def clean_schema(node, depth, counter)
      raise Invalid, "schema too deep" if depth > MAX_DEPTH
      counter[:nodes] += 1
      raise Invalid, "schema too complex" if counter[:nodes] > MAX_NODES
      return node if node == true || node == false
      raise Invalid, "sub-schema must be an object" unless node.is_a?(Hash)

      node.each_with_object({}) do |(key, value), out|
        key = key.to_s
        next unless SUPPORTED_KEYS.include?(key)

        out[key] =
          if SCHEMA_MAPS.include?(key)
            raise Invalid, "#{key} must be an object" unless value.is_a?(Hash)
            value.to_h { |name, sub| [name.to_s, clean_schema(sub, depth + 1, counter)] }
          elsif SCHEMA_LISTS.include?(key)
            raise Invalid, "#{key} must be a list" unless value.is_a?(Array)
            value.map { |sub| clean_schema(sub, depth + 1, counter) }
          elsif SCHEMA_VALUES.include?(key)
            value.is_a?(Array) ? value.map { |sub| clean_schema(sub, depth + 1, counter) } : clean_schema(value, depth + 1, counter)
          else
            value
          end
      end
    end
  end
end
