# frozen_string_literal: true

# Ruby conformance entrypoint (SPEC/20-b1-canon-1.md §5).
#
#   stdin  : a JSON document
#   stdout : 64 lowercase hex digits + newline
#   stderr : a B1_ERR_* token when the document is rejected

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'b1/canon'

input = $stdin.read

# Input that is not valid UTF-8 cannot be represented by the profile. Saying so is the point:
# substituting replacement characters would silently change the document and its digest.
unless input.force_encoding(Encoding::UTF_8).valid_encoding?
  warn 'B1_ERR_INVALID_UTF8'
  exit 2
end

begin
  puts B1::Canon.digest_text(input)
rescue B1::Canon::Error => e
  warn e.token
  exit 2
end
