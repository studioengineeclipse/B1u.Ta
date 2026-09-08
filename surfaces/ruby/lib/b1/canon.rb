# frozen_string_literal: true

# B1-CANON-1 for Ruby. Normative definition: SPEC/20-b1-canon-1.md.
#
# JSON.parse is not used: it keeps the last of a set of duplicate member names, which is one of the
# silent repairs this profile exists to reject. The parser here is strict in the same way every
# other implementation is, which is what makes the corpus a real cross-check rather than a
# formality.

require 'digest'

module B1
  module Canon
    MAX_DEPTH = 64
    MAX_SAFE = 9_007_199_254_740_991
    KEY_RE = /\A[A-Za-z0-9_$.\-]{1,64}\z/
    ZERO_LINK = "b1c1:#{'0' * 64}"

    class Error < StandardError
      attr_reader :token

      def initialize(token, detail = '')
        @token = token
        super(detail.empty? ? token : "#{token}: #{detail}")
      end
    end

    # Distinguishes an object from an array, which a bare Ruby Hash/Array pair already does — but
    # the wrapper keeps the parsed shape explicit and stops a Hash with symbol keys leaking in.
    Obj = Struct.new(:members) do
      def get(key) = members[key]
    end

    class Parser
      def initialize(text)
        @s = text
        @i = 0
        @n = text.length
      end

      def parse
        ws
        v = value(0)
        ws
        raise Error.new('B1_ERR_PARSE', 'trailing input') unless @i == @n

        v
      end

      private

      def ws
        @i += 1 while @i < @n && [' ', "\t", "\n", "\r"].include?(@s[@i])
      end

      def literal(word)
        raise Error.new('B1_ERR_PARSE', "expected #{word}") unless @s[@i, word.length] == word

        @i += word.length
      end

      def value(depth)
        raise Error.new('B1_ERR_DEPTH', "depth > #{MAX_DEPTH}") if depth > MAX_DEPTH
        raise Error.new('B1_ERR_PARSE', 'unexpected end of input') if @i >= @n

        case @s[@i]
        when '{' then object(depth)
        when '[' then array(depth)
        when '"' then string
        when 't' then literal('true') || true
        when 'f' then literal('false') || false
        when 'n' then literal('null') || nil
        when '-', '0'..'9' then number
        else raise Error.new('B1_ERR_PARSE', "unexpected character #{@s[@i].inspect}")
        end
      end

      def object(depth)
        @i += 1
        members = {}
        ws
        if @s[@i] == '}'
          @i += 1
          return Obj.new(members)
        end

        loop do
          ws
          raise Error.new('B1_ERR_PARSE', 'expected key') unless @s[@i] == '"'

          key = string
          raise Error.new('B1_ERR_KEY_SYNTAX', key) unless key.match?(KEY_RE)
          raise Error.new('B1_ERR_DUPLICATE_KEY', key) if members.key?(key)

          ws
          raise Error.new('B1_ERR_PARSE', "expected ':'") unless @s[@i] == ':'

          @i += 1
          ws
          members[key] = value(depth + 1)
          ws
          case @s[@i]
          when ',' then @i += 1
          when '}' then (@i += 1) && (return Obj.new(members))
          else raise Error.new('B1_ERR_PARSE', "expected ',' or '}'")
          end
        end
      end

      def array(depth)
        @i += 1
        items = []
        ws
        if @s[@i] == ']'
          @i += 1
          return items
        end

        loop do
          ws
          items << value(depth + 1)
          ws
          case @s[@i]
          when ',' then @i += 1
          when ']' then (@i += 1) && (return items)
          else raise Error.new('B1_ERR_PARSE', "expected ',' or ']'")
          end
        end
      end

      def number
        start = @i
        @i += 1 if @s[@i] == '-'
        digits_start = @i
        @i += 1 while @i < @n && @s[@i] >= '0' && @s[@i] <= '9'
        raise Error.new('B1_ERR_PARSE', 'expected digits') if @i == digits_start
        if @i - digits_start > 1 && @s[digits_start] == '0'
          raise Error.new('B1_ERR_PARSE', 'leading zero')
        end
        if ['.', 'e', 'E'].include?(@s[@i])
          raise Error.new('B1_ERR_NONINTEGER_NUMBER', 'non-integer')
        end

        text = @s[start...@i]
        raise Error.new('B1_ERR_NONINTEGER_NUMBER', 'negative zero') if text == '-0'

        v = Integer(text, 10)
        if v > MAX_SAFE || v < -MAX_SAFE
          raise Error.new('B1_ERR_NONINTEGER_NUMBER', "out of range: #{text}")
        end

        v
      end

      def hex4
        hex = @s[@i, 4]
        raise Error.new('B1_ERR_PARSE', 'bad \\u escape') unless hex&.match?(/\A[0-9a-fA-F]{4}\z/)

        @i += 4
        hex.to_i(16)
      end

      # Joins a surrogate pair into one scalar; either half alone is rejected (SPEC/20 R3).
      def unicode_escape
        cp = hex4
        if cp >= 0xD800 && cp <= 0xDBFF
          unless @s[@i] == '\\' && @s[@i + 1] == 'u'
            raise Error.new('B1_ERR_INVALID_UTF8', 'unpaired high surrogate')
          end

          @i += 2
          low = hex4
          unless low >= 0xDC00 && low <= 0xDFFF
            raise Error.new('B1_ERR_INVALID_UTF8', 'high surrogate without a low one')
          end

          return (0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)).chr(Encoding::UTF_8)
        end
        if cp >= 0xDC00 && cp <= 0xDFFF
          raise Error.new('B1_ERR_INVALID_UTF8', 'unpaired low surrogate')
        end

        cp.chr(Encoding::UTF_8)
      end

      def string
        @i += 1
        out = +''
        loop do
          raise Error.new('B1_ERR_PARSE', 'unterminated string') if @i >= @n

          c = @s[@i]
          if c == '"'
            @i += 1
            return out
          end

          if c == '\\'
            @i += 1
            e = @s[@i]
            raise Error.new('B1_ERR_PARSE', 'unterminated escape') if e.nil?

            @i += 1
            out << case e
                   when '"' then '"'
                   when '\\' then '\\'
                   when '/' then '/'
                   when 'b' then "\b"
                   when 'f' then "\f"
                   when 'n' then "\n"
                   when 'r' then "\r"
                   when 't' then "\t"
                   when 'u' then unicode_escape
                   else raise Error.new('B1_ERR_PARSE', "bad escape \\#{e}")
                   end
            next
          end

          raise Error.new('B1_ERR_PARSE', 'raw control character') if c.ord < 0x20

          out << c
          @i += 1
        end
      end
    end

    SHORT_ESCAPES = {
      '"' => '\\"', '\\' => '\\\\', "\b" => '\\b', "\t" => '\\t',
      "\n" => '\\n', "\f" => '\\f', "\r" => '\\r'
    }.freeze

    module_function

    def escape(str)
      out = +'"'
      str.each_char do |ch|
        short = SHORT_ESCAPES[ch]
        if short
          out << short
        elsif ch.ord < 0x20
          out << format('\\u%04x', ch.ord) # lowercase, per R3
        else
          out << ch
        end
      end
      out << '"'
    end

    def canonicalize(value, depth = 0)
      raise Error.new('B1_ERR_DEPTH', "depth > #{MAX_DEPTH}") if depth > MAX_DEPTH

      case value
      when nil then 'null'
      when true then 'true'
      when false then 'false'
      when Integer
        if value > MAX_SAFE || value < -MAX_SAFE
          raise Error.new('B1_ERR_NONINTEGER_NUMBER', 'out of range')
        end

        value.to_s
      when Float
        raise Error.new('B1_ERR_NONINTEGER_NUMBER', 'floating point is not representable')
      when String then escape(value)
      when Array
        "[#{value.map { |v| canonicalize(v, depth + 1) }.join(',')}]"
      when Obj then canonicalize_members(value.members, depth)
      when Hash then canonicalize_members(value, depth)
      else raise Error.new('B1_ERR_PARSE', "unsupported type #{value.class}")
      end
    end

    def canonicalize_members(members, depth)
      # R2 restricts names to ASCII, so a byte-order sort is the canonical order and means the same
      # thing in all fourteen languages.
      keys = members.keys.map(&:to_s).sort
      parts = keys.map do |k|
        raise Error.new('B1_ERR_KEY_SYNTAX', k) unless k.match?(KEY_RE)

        value = members.key?(k) ? members[k] : members[k.to_sym]
        "#{escape(k)}:#{canonicalize(value, depth + 1)}"
      end
      "{#{parts.join(',')}}"
    end

    def parse(text)
      Parser.new(text).parse
    end

    def digest_value(value)
      Digest::SHA256.hexdigest(canonicalize(value))
    end

    def digest_text(text)
      digest_value(parse(text))
    end

    # The prefix labels the algorithm and is not part of the hashed input.
    def b1c1(digest_hex) = "b1c1:#{digest_hex}"
  end
end
