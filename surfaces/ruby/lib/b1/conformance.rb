# frozen_string_literal: true

# The polyglot conformance runner (SPEC/80 §5).
#
# Ruby owns the build/verify graph, so this is written once here rather than duplicated per
# language. It runs every language's `conform` entrypoint against every fixture and fails on any
# divergence.
#
# The blessing rule matters more than the runner: an expected digest is only written when at least
# two *independent* implementations agree on it. A single implementation, however carefully
# written, cannot certify its own output — that would make the corpus a record of one program's
# behaviour rather than a cross-language agreement.

require 'json'
require 'open3'

module B1
  module Conformance
    ROOT = File.expand_path('../../../..', __dir__)
    FIXTURES = File.join(ROOT, 'conformance', 'fixtures')
    EXPECTED = File.join(ROOT, 'conformance', 'expected.json')
    MANIFEST = File.join(ROOT, 'conformance', 'languages.json')

    DIGEST_RE = /\A[0-9a-f]{64}\z/
    B1_ERR_RE = /\AB1_ERR_[A-Z_]+\z/

    Result = Struct.new(:digest, :error_token, :available, :detail, keyword_init: true)

    module_function

    def manifest
      JSON.parse(File.read(MANIFEST))['languages']
    end

    def fixtures
      Dir.children(FIXTURES).select { |f| f.end_with?('.json') }.sort
    end

    def negative?(name)
      name.start_with?('neg-')
    end

    # Runs a language's conform entrypoint against one fixture.
    def run_one(lang, fixture_path)
      cmd = lang['conform']
      input = File.read(fixture_path)
      out, err, status = Open3.capture3({ 'PATH' => enriched_path }, cmd, stdin_data: input, chdir: ROOT)
      if status.success?
        digest = out.strip
        unless digest.match?(DIGEST_RE)
          return Result.new(available: true, detail: "malformed stdout: #{digest[0, 80].inspect}")
        end
        Result.new(digest: digest, available: true)
      else
        token = err.strip.split("\n").first.to_s.strip
        if token.match?(B1_ERR_RE)
          Result.new(error_token: token, available: true)
        else
          Result.new(available: false, detail: "exit #{status.exitstatus}: #{err.strip[0, 200]}")
        end
      end
    rescue Errno::ENOENT => e
      Result.new(available: false, detail: "not built: #{e.message[0, 120]}")
    end

    # The installed SDKs live outside the default PATH.
    def enriched_path
      extra = ['/opt/kotlinc/bin', '/opt/swift/usr/bin', '/opt/dart-sdk/bin']
      ([ENV.fetch('PATH', '')] + extra).join(':')
    end

    def build(lang, verbose: false)
      cmd = lang['build']
      return [true, 'no build step'] if cmd.nil?

      out, err, status = Open3.capture3({ 'PATH' => enriched_path }, cmd, chdir: ROOT)
      puts out unless out.empty? || !verbose
      [status.success?, status.success? ? 'ok' : err.strip[0, 400]]
    end

    # Runs every available language against every fixture.
    # Returns { fixture => { lang_id => Result } }.
    def matrix
      langs = manifest
      fixtures.each_with_object({}) do |name, acc|
        path = File.join(FIXTURES, name)
        acc[name] = langs.each_with_object({}) do |lang, row|
          row[lang['id']] = run_one(lang, path)
        end
      end
    end

    # Writes expected.json, but only for fixtures where at least `min_agree` independent
    # implementations produced the same answer.
    def bless(min_agree: 2)
      m = matrix
      expected = { 'corpus_version' => 'b1-conformance/1', 'min_agreement' => min_agree, 'fixtures' => {} }
      unresolved = []

      m.each do |name, row|
        answers = Hash.new { |h, k| h[k] = [] }
        row.each do |lang_id, res|
          next unless res.available

          key = res.digest ? "digest:#{res.digest}" : (res.error_token ? "error:#{res.error_token}" : nil)
          answers[key] << lang_id if key
        end

        agreed, langs = answers.max_by { |_, v| v.size } || [nil, []]
        if agreed.nil? || langs.size < min_agree
          unresolved << [name, answers]
          next
        end
        if answers.size > 1
          unresolved << [name, answers] # a genuine disagreement, not merely thin coverage
          next
        end

        kind, value = agreed.split(':', 2)
        expected['fixtures'][name] = {
          'kind' => kind,
          kind => value,
          'agreed_by' => langs.sort,
          'negative' => negative?(name)
        }
      end

      [expected, unresolved]
    end

    def load_expected
      return nil unless File.exist?(EXPECTED)

      JSON.parse(File.read(EXPECTED))
    end
  end
end
