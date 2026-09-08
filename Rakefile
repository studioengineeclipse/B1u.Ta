# frozen_string_literal: true

# The polyglot build and verification graph. Ruby owns this (SPEC/80 §2).
#
#   rake build           build every language that has a build step
#   rake conform         verify all fourteen agree with conformance/expected.json
#   rake conform:matrix  show the full language x fixture matrix
#   rake conform:bless   (re)write expected.json from cross-implementation agreement
#   rake probe           derive the participation status table from what actually runs
#   rake verify          build, conform, probe

$LOAD_PATH.unshift File.expand_path('surfaces/ruby/lib', __dir__)

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
task verify: %i[build conform probe]
