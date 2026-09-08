<?php

declare(strict_types=1);

/**
 * The evidence library. Normative: SPEC/70-provider-routes.md §6.
 *
 * Two stores, deliberately separate:
 *   evidence/sora/      observations supplied by the user or project
 *   evidence/provider/  observations this system made itself
 *
 * The rule this file exists to enforce is the transfer law. Sora evidence is knowledge — prompting
 * lessons, shot construction, continuity technique, failure modes. It is not model weights, not a
 * hidden API, and not proof that another model behaves the same way. So a record from one provider
 * entering the pipeline for a different one is downgraded to HYPOTHESIS_ONLY, and the only thing
 * that can promote it is an observed experiment on that provider.
 *
 * The downgrade happens in applicableTo() rather than in a review checklist, because a rule that
 * lives only in prose is one nobody runs.
 *
 * Serve with:  php -S 127.0.0.1:8081 surfaces/php/evidence.php
 */

require_once __DIR__ . '/canon.php';

// Overridable so the transfer law can be tested against a fixture store without writing
// fabricated observations into the real one.
$B1_EVIDENCE_ROOT = getenv('B1_EVIDENCE_ROOT') ?: (__DIR__ . '/../../evidence');

const TRANSFERABILITY = [
    'PROVIDER_SPECIFIC',      // observed on this provider
    'CROSS_PROVIDER_OBSERVED', // observed to hold on more than one
    'HYPOTHESIS_ONLY',        // a lead, not a finding
    'UNKNOWN',
];

/**
 * @return list<array<string, mixed>>
 */
function load_store(string $store): array
{
    global $B1_EVIDENCE_ROOT;
    $dir = $B1_EVIDENCE_ROOT . '/' . $store;
    if (!is_dir($dir)) {
        return [];
    }
    $records = [];
    foreach (glob($dir . '/*.jsonl') ?: [] as $path) {
        foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $lineNo => $line) {
            try {
                $parsed = (new B1Parser($line))->parse();
            } catch (B1Exception $e) {
                // A malformed record is reported, never skipped silently: a store that quietly
                // drops what it cannot read misrepresents how much evidence there is.
                $records[] = [
                    'record_id' => null,
                    'store' => $store,
                    'source' => basename($path) . ':' . ($lineNo + 1),
                    'observation' => 'MALFORMED RECORD — ' . $e->token,
                    'transferability' => 'UNKNOWN',
                    'confidence_ppm' => 0,
                    'malformed' => true,
                ];
                continue;
            }
            if (!$parsed instanceof B1Obj) {
                continue;
            }
            $rec = [];
            foreach ($parsed->members as $k => $v) {
                $rec[$k] = $v instanceof B1Arr ? $v->items : $v;
            }
            $rec['store'] = $store;
            $rec['malformed'] = false;
            $records[] = $rec;
        }
    }
    return $records;
}

/**
 * How a record may be used for a given provider.
 *
 * This is the transfer law in code. A record observed on provider A says nothing verified about
 * provider B; asked about B, it comes back as a hypothesis with its confidence stripped, because
 * carrying the original confidence across would be exactly the "worked in Sora, so it will work in
 * Seedance" collapse the specification forbids.
 *
 * @param array<string, mixed> $record
 * @return array<string, mixed>
 */
function applicable_to(array $record, ?string $targetProvider): array
{
    $observedOn = $record['applicable_provider'] ?? null;
    $stated = $record['transferability'] ?? 'UNKNOWN';

    if ($targetProvider === null || $observedOn === null) {
        return $record + ['effective_transferability' => $stated, 'downgraded' => false];
    }

    if ($observedOn === $targetProvider) {
        return $record + ['effective_transferability' => $stated, 'downgraded' => false];
    }

    if ($stated === 'CROSS_PROVIDER_OBSERVED') {
        // Observed to hold across providers — still not a guarantee for an untested one, but it is
        // a stronger lead than a single-provider observation.
        return $record + ['effective_transferability' => 'HYPOTHESIS_ONLY', 'downgraded' => true]
            + ['downgrade_reason' => "observed across providers but not on $targetProvider"];
    }

    return array_merge($record, [
        'effective_transferability' => 'HYPOTHESIS_ONLY',
        'downgraded' => true,
        'downgrade_reason' => "observed on " . (string) $observedOn . ", not on $targetProvider; "
            . "usable as a hypothesis to test, never as a finding",
        'confidence_ppm' => 0,
    ]);
}

/** @return list<array<string, mixed>> */
function all_records(?string $targetProvider, ?string $store): array
{
    $stores = $store !== null ? [$store] : ['sora', 'provider'];
    $out = [];
    foreach ($stores as $s) {
        foreach (load_store($s) as $rec) {
            $out[] = applicable_to($rec, $targetProvider);
        }
    }
    return $out;
}

function respond_json(mixed $data): void
{
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), "\n";
}

function e(string $s): string
{
    return htmlspecialchars($s, ENT_QUOTES, 'UTF-8');
}

// --- routing ------------------------------------------------------------------

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$provider = isset($_GET['provider']) && $_GET['provider'] !== '' ? (string) $_GET['provider'] : null;
$store = isset($_GET['store']) && $_GET['store'] !== '' ? (string) $_GET['store'] : null;

if ($path === '/api/evidence') {
    respond_json([
        'target_provider' => $provider,
        'transfer_law' => 'Evidence observed on one provider is a hypothesis about another, never a '
            . 'finding. Records not observed on the target provider are returned as HYPOTHESIS_ONLY '
            . 'with confidence stripped.',
        'records' => all_records($provider, $store),
    ]);
    exit;
}

if ($path === '/api/stores') {
    respond_json([
        'sora' => count(load_store('sora')),
        'provider' => count(load_store('provider')),
        'transferability_values' => TRANSFERABILITY,
    ]);
    exit;
}

$records = all_records($provider, $store);
$downgraded = array_filter($records, static fn ($r) => ($r['downgraded'] ?? false) === true);

?><!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>B1 Evidence Library</title>
<style>
  body { font: 14px/1.5 system-ui, sans-serif; margin: 2rem auto; max-width: 60rem; color: #1b1b1b; }
  h1 { font-size: 1.3rem; margin-bottom: .2rem; }
  .law { background: #f5f3ee; border-left: 3px solid #8a7f66; padding: .8rem 1rem; margin: 1rem 0; }
  form { margin: 1rem 0; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: .5rem .6rem; border-bottom: 1px solid #e4e0d8; vertical-align: top; }
  th { font-weight: 600; background: #faf9f6; }
  .tag { font-size: .78rem; padding: .1rem .45rem; border-radius: 3px; white-space: nowrap; }
  .PROVIDER_SPECIFIC { background: #dcefdc; }
  .CROSS_PROVIDER_OBSERVED { background: #d8e8f5; }
  .HYPOTHESIS_ONLY { background: #f6ecd2; }
  .UNKNOWN { background: #ececec; }
  .down { color: #7a5c00; font-size: .82rem; }
  .empty { color: #666; font-style: italic; padding: 2rem 0; }
</style>
</head>
<body>
<h1>B1 Evidence Library</h1>

<div class="law">
  <strong>Transfer law.</strong> Evidence observed on one provider is a <em>hypothesis</em> about
  another, never a finding. Sora evidence is knowledge — prompting lessons, shot construction,
  continuity technique, failure modes. It is not model weights, not a hidden API, and not proof that
  another model behaves the same way.
  <br>
  Filtering by a target provider downgrades every record not observed on it to
  <code>HYPOTHESIS_ONLY</code> and strips its confidence. The only thing that promotes a hypothesis
  is an observed experiment on that provider.
</div>

<form method="get">
  <label>Target provider:
    <input name="provider" value="<?= e($provider ?? '') ?>" placeholder="e.g. seedance">
  </label>
  <label>Store:
    <select name="store">
      <option value="">both</option>
      <option value="sora" <?= $store === 'sora' ? 'selected' : '' ?>>sora</option>
      <option value="provider" <?= $store === 'provider' ? 'selected' : '' ?>>provider</option>
    </select>
  </label>
  <button type="submit">Apply</button>
</form>

<?php if ($provider !== null && count($downgraded) > 0): ?>
  <p class="down">
    <?= count($downgraded) ?> of <?= count($records) ?> record(s) were downgraded to
    HYPOTHESIS_ONLY for <code><?= e($provider) ?></code>.
  </p>
<?php endif; ?>

<?php if (count($records) === 0): ?>
  <p class="empty">
    No evidence records. The stores are empty because nothing has been observed yet — this system
    has never called a provider. Records appear here as experiments are run and recorded; they are
    not seeded with plausible-looking examples.
  </p>
<?php else: ?>
<table>
  <tr>
    <th>Store</th><th>Observation</th><th>Provider</th><th>Transferability</th>
    <th>Confidence</th><th>Failure cases</th>
  </tr>
  <?php foreach ($records as $r): ?>
  <tr>
    <td><?= e((string) ($r['store'] ?? '')) ?></td>
    <td>
      <?= e((string) ($r['observation'] ?? '')) ?>
      <?php if (!empty($r['downgraded'])): ?>
        <div class="down">↓ <?= e((string) ($r['downgrade_reason'] ?? '')) ?></div>
      <?php endif; ?>
    </td>
    <td><?= e((string) ($r['applicable_provider'] ?? '—')) ?></td>
    <td>
      <span class="tag <?= e((string) ($r['effective_transferability'] ?? 'UNKNOWN')) ?>">
        <?= e((string) ($r['effective_transferability'] ?? 'UNKNOWN')) ?>
      </span>
    </td>
    <td><?= (int) ($r['confidence_ppm'] ?? 0) ?> ppm</td>
    <td><?= e(implode('; ', array_map('strval', (array) ($r['failure_cases'] ?? [])))) ?></td>
  </tr>
  <?php endforeach; ?>
</table>
<?php endif; ?>

</body>
</html>
