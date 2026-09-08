# frozen_string_literal: true

# The polyglot build and verification graph. Ruby owns this (SPEC/80 §2).
#
#   rake build           build every language that has a build step
#   rake conform         verify all fourteen agree with conformance/expected.json
#   rake conform:matrix  show the full language x fixture matrix
#   rake conform:bless   (re)write expected.json from cross-implementation agreement
#   rake probe           derive the participation status table from what actually runs
#   rake test            run every component's own test suite
#   rake verify          build, test, conform, probe

$LOAD_PATH.unshift File.expand_path('surfaces/ruby/lib', __dir__)

require 'fileutils'
require 'open3'
require 'b1/conformance'

RED = "\e[31m"
GREEN = "\e[32m"
YELLOW = "\e[33m"
DIM = "\e[2m"
OFF = "\e[0m"

def ok(s)   = "#{GREEN}#{s}#{OFF}"
def bad(s)  = "#{RED}#{s}#{OFF}"
def warn_(s) = "#{YELLOW}#{s}#{OFF}"

task default: :verify

desc 'Build every language that has a build step'
task :build do
  failures = []
  B1::Conformance.manifest.each do |lang|
    next if lang['build'].nil?

    print format('%-12s ', lang['id'])
    success, detail = B1::Conformance.build(lang)
    if success
      puts ok('built')
    else
      puts bad('FAILED')
      puts "#{DIM}#{detail}#{OFF}"
      failures << lang['id']
    end
  end
  B1::Conformance.manifest.select { |l| l['build'].nil? }.each do |lang|
    puts format('%-12s %s', lang['id'], "#{DIM}no build step#{OFF}")
  end
  abort(bad("build failed: #{failures.join(', ')}")) unless failures.empty?
end

desc 'Verify every language agrees with conformance/expected.json'
task :conform do
  expected = B1::Conformance.load_expected
  abort(bad('conformance/expected.json missing — run `rake conform:bless` first')) if expected.nil?

  langs = B1::Conformance.manifest
  divergences = []
  unavailable = Hash.new(0)
  checks = 0

  B1::Conformance.fixtures.each do |name|
    exp = expected['fixtures'][name]
    next if exp.nil?

    path = File.join(B1::Conformance::FIXTURES, name)
    langs.each do |lang|
      res = B1::Conformance.run_one(lang, path)
      unless res.available
        unavailable[lang['id']] += 1
        next
      end
      checks += 1
      actual = res.digest ? "digest:#{res.digest}" : "error:#{res.error_token}"
      wanted = "#{exp['kind']}:#{exp[exp['kind']]}"
      divergences << [name, lang['id'], wanted, actual] if actual != wanted
    end
  end

  puts "checks: #{checks}"
  unavailable.each { |id, n| puts warn_("#{id}: not available for #{n} fixtures") }

  if divergences.empty?
    puts ok("CONFORM OK — every available language agrees across #{B1::Conformance.fixtures.size} fixtures")
  else
    divergences.each do |name, id, wanted, actual|
      puts bad("DIVERGENCE #{name} [#{id}]")
      puts "  expected #{wanted}"
      puts "  actual   #{actual}"
    end
    abort(bad("#{divergences.size} divergence(s)"))
  end
end

namespace :conform do
  desc 'Show the full language x fixture matrix'
  task :matrix do
    langs = B1::Conformance.manifest
    puts format('%-24s %s', 'fixture', langs.map { |l| l['id'][0, 4].ljust(5) }.join)
    B1::Conformance.fixtures.each do |name|
      path = File.join(B1::Conformance::FIXTURES, name)
      cells = langs.map do |lang|
        res = B1::Conformance.run_one(lang, path)
        cell = if !res.available then "#{DIM}·#{OFF}"
               elsif res.digest then res.digest[0, 4]
               else res.error_token.sub('B1_ERR_', '')[0, 4]
               end
        cell.ljust(res.available ? 5 : 5 + DIM.length + OFF.length)
      end
      puts format('%-24s %s', name, cells.join)
    end
  end

  desc 'Write expected.json from cross-implementation agreement'
  task :bless do
    expected, unresolved = B1::Conformance.bless
    File.write(B1::Conformance::EXPECTED, JSON.pretty_generate(expected) + "\n")
    puts ok("blessed #{expected['fixtures'].size} fixtures")

    unless unresolved.empty?
      puts warn_("#{unresolved.size} unresolved (thin coverage or genuine disagreement):")
      unresolved.each do |name, answers|
        puts "  #{name}"
        answers.each { |k, v| puts "    #{k[0, 78]}  <- #{v.join(', ')}" }
      end
    end
  end
end

desc 'Derive the participation status table from what actually runs'
task :probe do
  sh 'python3 tools/probe.py'
end

desc 'Build, conform, probe'
task verify: %i[build test conform probe]

desc 'Generate the executive handoff from repository state'
task :report do
  require 'b1/report'
  out = File.join(__dir__, 'state', 'executive-handoff.md')
  FileUtils.mkdir_p(File.dirname(out))
  File.write(out, B1::Report.new.to_markdown)
  puts ok("wrote #{out.sub(__dir__ + '/', '')}")
end

desc 'Compile a scene written in the authoring DSL'
task :compile, [:scene] do |_t, args|
  abort(bad('usage: rake compile[examples/scene.b1.rb]')) if args[:scene].nil?
  sh "ruby surfaces/ruby/compile_dsl.rb #{args[:scene]}"
end

# Every component's own tests. The conformance corpus proves the fourteen languages agree on the
# contract; these prove each component does the job it owns. Both are needed: a language can
# canonicalize perfectly and still get its actual responsibility wrong.
COMPONENT_TESTS = [
  ['C kernel',            'make -s -C core/c test'],
  ['C++ analyzer',        'make -s -C core/cpp test'],
  ['Rust trusted core',   'cargo test --quiet --offline --manifest-path core/rust/Cargo.toml'],
  ['Python quality',      'python3 -m unittest discover -s engine/python/tests -q'],
  ['Kotlin continuity',   'java -cp engine/jvm/kotlin/build/b1continuity.jar:engine/jvm/java/build b1.continuity.MainKt selftest'],
  ['Swift references',    'engine/swift/build/b1reference selftest'],
  ['C# convergence',      'dotnet engine/csharp/B1.Convergence/bin/Release/net8.0/B1.Convergence.dll selftest'],
  ['PHP evidence',        './surfaces/php/run_tests.sh'],
  ['Dart presenter',      'cd engine/dart && dart run bin/conform.dart selftest']
].freeze

# Extracts an accurate count rather than the first thing that looks like one.
#
# A single loose regex is wrong here in a way that matters: cargo prints a "test result" line per
# binary, most of them with zero tests, so matching the first left the Rust suite reporting
# "0 tests" while it was actually running fifteen. A summary that can silently say zero for a
# passing suite hides the empty run it exists to reveal.
def summarize(output)
  cargo = output.scan(/test result: ok\. (\d+) passed/).flatten.map(&:to_i).sum
  return "#{cargo} tests" if cargo.positive?

  unittest = output[/Ran (\d+) tests?/, 1]
  return "#{unittest} tests" if unittest

  checks = output.scan(/^\s+ok\s{2,}\S/).size
  return "#{checks} checks" if checks.positive?

  'passed (no count reported)'
end

desc 'Run every component test suite'
task :test do
  failures = []
  COMPONENT_TESTS.each do |name, cmd|
    print format('%-22s ', name)
    out, err, status = Open3.capture3({ 'PATH' => B1::Conformance.enriched_path }, cmd, chdir: __dir__)
    if status.success?
      puts ok(summarize(out + err))
    else
      puts bad('FAILED')
      failures << [name, (out + err).lines.last(12).join.strip]
    end
  end

  unless failures.empty?
    failures.each do |name, detail|
      puts bad("\n#{name}:")
      puts "#{DIM}#{detail}#{OFF}"
    end
    abort(bad("#{failures.size} component suite(s) failed"))
  end
  puts ok("\nall #{COMPONENT_TESTS.size} component suites passed")
end
