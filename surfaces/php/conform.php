<?php

declare(strict_types=1);

/**
 * PHP conformance entrypoint (SPEC/20-b1-canon-1.md §5).
 *
 *   stdin  : a JSON document
 *   stdout : 64 lowercase hex digits + newline
 *   stderr : a B1_ERR_* token when the document is rejected
 */

require_once __DIR__ . '/canon.php';

$input = stream_get_contents(STDIN);
if ($input === false) {
    fwrite(STDERR, "B1_ERR_PARSE\n");
    exit(2);
}

try {
    echo b1_digest_text($input), "\n";
} catch (B1Exception $e) {
    fwrite(STDERR, $e->token . "\n");
    exit(2);
}
