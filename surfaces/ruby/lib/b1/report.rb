# frozen_string_literal: true

# Executive handoff generation (SPEC/00 §31 lineage).
#
# The report is assembled from what the repository actually contains — the probe output, the ledger,
# the emitted packages, the discovery result — rather than from a template describing what it is
# supposed to contain. A handoff that says "ten of fourteen languages integrate" because someone
# typed that is worth nothing; this one says it because it read state/participation.json, and says
# "not probed yet" when that file is absent.

require 'json'
require_relative 'canon'

module B1
  class Report
    ROOT = File.expand_path('../../../..', __dir__)

    def initialize(root: ROOT)
      @root = root
    end

    def participation
      path = File.join(@root, 'state', 'participation.json')
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    end

    def ledger_records
      path = File.join(@root, 'state', 'ledger.jsonl')
      return [] unless File.exist?(path)

      File.readlines(path).reject { |l| l.strip.empty? }.map do |line|
        B1::Canon.parse(line)
      rescue B1::Canon::Error
        nil
      end.compact
    end

    def packages
      Dir.glob(File.join(@root, 'state', 'packages', '*.json')).sort.map do |path|
        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end.compact
    end

    def spec_documents
      Dir.glob(File.join(@root, 'SPEC', '*.md')).sort.map { |p| File.basename(p) }
    end

    # Reads the honest execution status straight from the emitted packages rather than assuming it.
    def execution_summary
      pkgs = packages
      return { 'count' => 0, 'statuses' => {}, 'routes' => {} } if pkgs.empty?

      {
        'count' => pkgs.size,
        'statuses' => pkgs.group_by { |p| p['execution_status'] }.transform_values(&:size),
        'routes' => pkgs.group_by { |p| p['route'] }.transform_values(&:size)
      }
    end

    def to_markdown
      part = participation
      langs = part ? part['languages'] : []
      integrating = langs.count { |l| %w[INTEGRATES EFFECT_VERIFIED POSTCONDITION_VERIFIED].include?(l['status']) }
      exec = execution_summary

      lines = []
      lines << '# B1μ-DQAS Ω13.9 — Executive Handoff'
      lines << ''
      lines << "Generated from repository state at #{Time.now.utc.strftime('%Y-%m-%d %H:%M UTC')}. "\
               'Every figure below was read from a file, not asserted.'
      lines << ''

      lines << '## Strategic goal'
      lines << ''
      lines << 'A provider-neutral orchestration and verification fabric for multimodal video '\
               'generation. The render model is a component; the canonical creative state belongs '\
               'to B1; provider receipts are evidence, not proof; observed media determines success.'
      lines << ''

      lines << '## Current verified state'
      lines << ''
      if part.nil?
        lines << 'Participation: **not probed**. Run `rake probe` — no status can be reported '\
                 'without it, and none is guessed here.'
      else
        lines << "Participation: **#{integrating}/14** languages at INTEGRATES or above, derived by "\
                 'compiling and running each toolchain against the conformance corpus.'
        lines << ''
        lines << '| Language | Responsibility | Status |'
        lines << '|---|---|---|'
        langs.each do |l|
          lines << "| #{l['name']} | #{l['responsibility']} | `#{l['status']}` |"
        end
      end
      lines << ''

      lines << "Normative documents: #{spec_documents.size} under `SPEC/` "\
               "(#{spec_documents.join(', ')})."
      lines << ''

      if exec['count'].zero?
        lines << 'Generation packages: none emitted yet.'
      else
        statuses = exec['statuses'].map { |k, v| "#{v} × `#{k}`" }.join(', ')
        routes = exec['routes'].map { |k, v| "#{v} × `#{k}`" }.join(', ')
        lines << "Generation packages: #{exec['count']} emitted — #{statuses}; routes: #{routes}."
      end

      records = ledger_records
      lines << "Ledger: #{records.size} record(s). Verify with `b1ledger verify`."
      lines << ''

      lines << '## Critical constraints'
      lines << ''
      lines << '- **No fabricated execution.** With no authorized provider the system emits complete '\
               'packages stamped `EXECUTION_STATUS = NOT_EXECUTED`. No placeholder media, no '\
               'synthesized receipt, no quality vector scored over output that does not exist.'
      lines << '- **No floating point in digest-bearing fields.** Durations in milliseconds, ratios '\
               'in parts-per-million, scores in milli-units. This is what makes fourteen-language '\
               'digest agreement achievable rather than aspirational.'
      lines << '- **Participation status is derived, never claimed.** `tools/probe.py` compiles and '\
               'runs each toolchain; prose cannot promote a language up the ladder.'
      lines << '- **A receipt is not an effect.** Receipt, observed effect and objective '\
               'postcondition are three separate ledger fields with three separate routes into '\
               '`IN_DOUBT`, and no path from "provider reported success" to `VERIFIED`.'
      lines << ''

      lines << '## Major dependencies'
      lines << ''
      lines << '- `B1-CANON-1` (SPEC/20). Everything downstream assumes it: IR identity, envelope '\
               'binding, ledger links, continuity signatures. A change here invalidates every '\
               'stored digest.'
      lines << '- `core/c/libb1sig` is the normative kernel. C++ links it over the C ABI; the frame '\
               'signature has exactly one definition.'
      lines << '- The conformance corpus is the interop contract. A new language is not integrated '\
               'until it agrees on all of it.'
      lines << ''

      lines << '## Important unknowns'
      lines << ''
      lines << '- **Real provider contracts.** No provider has been called, so every emitted request '\
               'shape is `CONTRACT_UNVERIFIED` and every capability field that was not observed is '\
               '`UNKNOWN`. This is the largest open item and it cannot be closed from here.'
      lines << '- **Semantic identity.** The analyzer measures structural and tonal similarity. It '\
               'cannot establish that a subject is the same person; every such score carries '\
               '`measurement_basis: PROXY` for that reason.'
      lines << '- **Evidence stores are empty**, because nothing has been observed. They are not '\
               'seeded with plausible examples.'
      lines << ''

      lines << '## Authority state'
      lines << ''
      lines << 'Analysis, planning, compilation and verification proceed autonomously. Every '\
               'persistent effect requires an authority envelope bound to a specific action, '\
               'target, scope, expected effect, assumed state and plan — revalidated at effect '\
               'time, not merely at planning time. A provider call that spends credits is a '\
               'persistent effect and has no standing authorization.'
      lines << ''

      lines << '## Next actions'
      lines << ''
      if integrating < 14
        remaining = langs.reject { |l| %w[INTEGRATES EFFECT_VERIFIED POSTCONDITION_VERIFIED].include?(l['status']) }
        lines << "1. Bring the remaining #{remaining.size} language(s) to INTEGRATES: "\
                 "#{remaining.map { |l| l['name'] }.join(', ')}."
      else
        lines << '1. All fourteen languages integrate. The invariant holds.'
      end
      lines << '2. Supply a provider credential and verify the live API contract *before* compiling '\
               'a request against it — a guessed contract spends credits to discover it was wrong.'
      lines << '3. Request effect-time authorization for the first credit-spending generation. It '\
               'is not covered by any existing envelope.'
      lines << '4. Once media exists, run the closed loop through analysis and scoring so a quality '\
               'vector rests on observed output rather than on nothing.'
      lines << ''

      lines << '---'
      lines << ''
      lines << '_Generated by `rake report` from repository state._'
      lines.join("\n") + "\n"
    end
  end
end
