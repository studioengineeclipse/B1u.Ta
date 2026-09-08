<?php

declare(strict_types=1);

/**
 * B1-CANON-1 for PHP. Normative definition: SPEC/20-b1-canon-1.md.
 *
 * json_decode is not used: it keeps the last of a set of duplicate member names, and PHP arrays
 * cannot distinguish an empty object from an empty array. Both would silently change a document
 * this profile is required to reject or to digest exactly.
 */

final class B1Exception extends RuntimeException
{
    public function __construct(public readonly string $token, string $detail = '')
    {
        parent::__construct($detail === '' ? $token : "$token: $detail");
    }
}

/** Distinguishes an object from an array, which a bare PHP array cannot. */
final class B1Obj
{
    /** @var array<string, mixed> */
    public array $members = [];

    public function get(string $key): mixed
    {
        return $this->members[$key] ?? null;
    }

    public function set(string $key, mixed $value): self
    {
        $this->members[$key] = $value;
        return $this;
    }
}

final class B1Arr
{
    /** @param list<mixed> $items */
    public function __construct(public array $items = [])
    {
    }
}

const B1_MAX_DEPTH = 64;
const B1_MAX_SAFE = 9007199254740991;

function b1_key_syntax_ok(string $k): bool
{
    return (bool) preg_match('/^[A-Za-z0-9_$.\-]{1,64}$/', $k);
}

final class B1Parser
{
    private int $i = 0;
    /** @var list<string> */
    private array $chars;

    public function __construct(private readonly string $s)
    {
        // Operate on code points: byte indexing would split multi-byte characters inside strings.
        $chars = preg_split('//u', $s, -1, PREG_SPLIT_NO_EMPTY);
        if ($chars === false) {
            throw new B1Exception('B1_ERR_INVALID_UTF8', 'input is not valid UTF-8');
        }
        $this->chars = $chars;
    }

    public function parse(): mixed
    {
        $this->ws();
        $v = $this->value(0);
        $this->ws();
        if ($this->i !== count($this->chars)) {
            throw new B1Exception('B1_ERR_PARSE', 'trailing input');
        }
        return $v;
    }

    private function ws(): void
    {
        while ($this->i < count($this->chars)
            && in_array($this->chars[$this->i], [' ', "\t", "\n", "\r"], true)) {
            $this->i++;
        }
    }

    private function literal(string $word): void
    {
        $chars = str_split($word);
        foreach ($chars as $k => $c) {
            if (($this->chars[$this->i + $k] ?? null) !== $c) {
                throw new B1Exception('B1_ERR_PARSE', "expected $word");
            }
        }
        $this->i += count($chars);
    }

    private function value(int $depth): mixed
    {
        if ($depth > B1_MAX_DEPTH) {
            throw new B1Exception('B1_ERR_DEPTH', 'depth > ' . B1_MAX_DEPTH);
        }
        if ($this->i >= count($this->chars)) {
            throw new B1Exception('B1_ERR_PARSE', 'unexpected end of input');
        }
        $c = $this->chars[$this->i];
        return match (true) {
            $c === '{' => $this->object($depth),
            $c === '[' => $this->array($depth),
            $c === '"' => $this->string(),
            $c === 't' => $this->boolLiteral('true', true),
            $c === 'f' => $this->boolLiteral('false', false),
            $c === 'n' => $this->nullLiteral(),
            $c === '-' || ($c >= '0' && $c <= '9') => $this->number(),
            default => throw new B1Exception('B1_ERR_PARSE', "unexpected character $c"),
        };
    }

    private function boolLiteral(string $word, bool $value): bool
    {
        $this->literal($word);
        return $value;
    }

    private function nullLiteral(): mixed
    {
        $this->literal('null');
        return null;
    }

    private function object(int $depth): B1Obj
    {
        $this->i++;
        $obj = new B1Obj();
        $this->ws();
        if (($this->chars[$this->i] ?? null) === '}') {
            $this->i++;
            return $obj;
        }
        while (true) {
            $this->ws();
            if (($this->chars[$this->i] ?? null) !== '"') {
                throw new B1Exception('B1_ERR_PARSE', 'expected key');
            }
            $key = $this->string();
            if (!b1_key_syntax_ok($key)) {
                throw new B1Exception('B1_ERR_KEY_SYNTAX', $key);
            }
            if (array_key_exists($key, $obj->members)) {
                throw new B1Exception('B1_ERR_DUPLICATE_KEY', $key);
            }
            $this->ws();
            if (($this->chars[$this->i] ?? null) !== ':') {
                throw new B1Exception('B1_ERR_PARSE', "expected ':'");
            }
            $this->i++;
            $this->ws();
            $obj->members[$key] = $this->value($depth + 1);
            $this->ws();
            $c = $this->chars[$this->i] ?? null;
            if ($c === ',') {
                $this->i++;
                continue;
            }
            if ($c === '}') {
                $this->i++;
                return $obj;
            }
            throw new B1Exception('B1_ERR_PARSE', "expected ',' or '}'");
        }
    }

    private function array(int $depth): B1Arr
    {
        $this->i++;
        $items = [];
        $this->ws();
        if (($this->chars[$this->i] ?? null) === ']') {
            $this->i++;
            return new B1Arr($items);
        }
        while (true) {
            $this->ws();
            $items[] = $this->value($depth + 1);
            $this->ws();
            $c = $this->chars[$this->i] ?? null;
            if ($c === ',') {
                $this->i++;
                continue;
            }
            if ($c === ']') {
                $this->i++;
                return new B1Arr($items);
            }
            throw new B1Exception('B1_ERR_PARSE', "expected ',' or ']'");
        }
    }

    private function number(): int
    {
        $start = $this->i;
        if ($this->chars[$this->i] === '-') {
            $this->i++;
        }
        $digitsStart = $this->i;
        while ($this->i < count($this->chars)
            && $this->chars[$this->i] >= '0' && $this->chars[$this->i] <= '9') {
            $this->i++;
        }
        if ($this->i === $digitsStart) {
            throw new B1Exception('B1_ERR_PARSE', 'expected digits');
        }
        if ($this->i - $digitsStart > 1 && $this->chars[$digitsStart] === '0') {
            throw new B1Exception('B1_ERR_PARSE', 'leading zero');
        }
        $next = $this->chars[$this->i] ?? null;
        if ($next === '.' || $next === 'e' || $next === 'E') {
            throw new B1Exception('B1_ERR_NONINTEGER_NUMBER', 'non-integer');
        }
        $text = implode('', array_slice($this->chars, $start, $this->i - $start));
        if ($text === '-0') {
            throw new B1Exception('B1_ERR_NONINTEGER_NUMBER', 'negative zero');
        }
        // Compare as a string before casting: an out-of-range literal would otherwise saturate or
        // wrap silently, turning a rejection into a wrong digest.
        $magnitude = ltrim($text, '-');
        if (strlen($magnitude) > 16
            || (strlen($magnitude) === 16 && bccomp_fallback($magnitude, (string) B1_MAX_SAFE) > 0)) {
            throw new B1Exception('B1_ERR_NONINTEGER_NUMBER', "out of range: $text");
        }
        $v = (int) $text;
        if ($v > B1_MAX_SAFE || $v < -B1_MAX_SAFE) {
            throw new B1Exception('B1_ERR_NONINTEGER_NUMBER', "out of range: $text");
        }
        return $v;
    }

    private function hex4(): int
    {
        $hex = implode('', array_slice($this->chars, $this->i, 4));
        if (strlen($hex) !== 4 || !ctype_xdigit($hex)) {
            throw new B1Exception('B1_ERR_PARSE', 'bad \\u escape');
        }
        $this->i += 4;
        return (int) hexdec($hex);
    }

    /** Joins a surrogate pair into one scalar; either half alone is rejected (SPEC/20 R3). */
    private function unicodeEscape(): string
    {
        $cp = $this->hex4();
        if ($cp >= 0xD800 && $cp <= 0xDBFF) {
            if (($this->chars[$this->i] ?? null) !== '\\' || ($this->chars[$this->i + 1] ?? null) !== 'u') {
                throw new B1Exception('B1_ERR_INVALID_UTF8', 'unpaired high surrogate');
            }
            $this->i += 2;
            $low = $this->hex4();
            if ($low < 0xDC00 || $low > 0xDFFF) {
                throw new B1Exception('B1_ERR_INVALID_UTF8', 'high surrogate without a low one');
            }
            return mb_chr(0x10000 + (($cp - 0xD800) << 10) + ($low - 0xDC00), 'UTF-8');
        }
        if ($cp >= 0xDC00 && $cp <= 0xDFFF) {
            throw new B1Exception('B1_ERR_INVALID_UTF8', 'unpaired low surrogate');
        }
        return mb_chr($cp, 'UTF-8');
    }

    private function string(): string
    {
        $this->i++;
        $out = '';
        while (true) {
            if ($this->i >= count($this->chars)) {
                throw new B1Exception('B1_ERR_PARSE', 'unterminated string');
            }
            $c = $this->chars[$this->i];
            if ($c === '"') {
                $this->i++;
                return $out;
            }
            if ($c === '\\') {
                $this->i++;
                $e = $this->chars[$this->i] ?? throw new B1Exception('B1_ERR_PARSE', 'unterminated escape');
                $this->i++;
                $out .= match ($e) {
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    'b' => "\x08",
                    'f' => "\x0c",
                    'n' => "\n",
                    'r' => "\r",
                    't' => "\t",
                    'u' => $this->unicodeEscape(),
                    default => throw new B1Exception('B1_ERR_PARSE', "bad escape \\$e"),
                };
                continue;
            }
            if (strlen($c) === 1 && ord($c) < 0x20) {
                throw new B1Exception('B1_ERR_PARSE', 'raw control character');
            }
            $out .= $c;
            $this->i++;
        }
    }
}

/** Compares two non-negative decimal strings without needing the bcmath extension. */
function bccomp_fallback(string $a, string $b): int
{
    $a = ltrim($a, '0') ?: '0';
    $b = ltrim($b, '0') ?: '0';
    if (strlen($a) !== strlen($b)) {
        return strlen($a) <=> strlen($b);
    }
    return strcmp($a, $b);
}

function b1_escape(string $s): string
{
    $out = '"';
    foreach (preg_split('//u', $s, -1, PREG_SPLIT_NO_EMPTY) ?: [] as $ch) {
        $out .= match ($ch) {
            '"' => '\\"',
            '\\' => '\\\\',
            "\x08" => '\\b',
            "\t" => '\\t',
            "\n" => '\\n',
            "\x0c" => '\\f',
            "\r" => '\\r',
            default => (strlen($ch) === 1 && ord($ch) < 0x20)
                ? sprintf('\\u%04x', ord($ch)) // lowercase, per R3
                : $ch,
        };
    }
    return $out . '"';
}

function b1_canonicalize(mixed $v, int $depth = 0): string
{
    if ($depth > B1_MAX_DEPTH) {
        throw new B1Exception('B1_ERR_DEPTH', 'depth > ' . B1_MAX_DEPTH);
    }
    if ($v === null) {
        return 'null';
    }
    if (is_bool($v)) {
        return $v ? 'true' : 'false';
    }
    if (is_int($v)) {
        if ($v > B1_MAX_SAFE || $v < -B1_MAX_SAFE) {
            throw new B1Exception('B1_ERR_NONINTEGER_NUMBER', 'out of range');
        }
        return (string) $v;
    }
    if (is_float($v)) {
        throw new B1Exception('B1_ERR_NONINTEGER_NUMBER', 'floating point is not representable');
    }
    if (is_string($v)) {
        return b1_escape($v);
    }
    if ($v instanceof B1Arr) {
        return '[' . implode(',', array_map(
            static fn ($item) => b1_canonicalize($item, $depth + 1),
            $v->items
        )) . ']';
    }
    if ($v instanceof B1Obj) {
        // R2 restricts names to ASCII, so a byte-order sort is the canonical order.
        $keys = array_keys($v->members);
        sort($keys, SORT_STRING);
        $parts = [];
        foreach ($keys as $k) {
            if (!b1_key_syntax_ok((string) $k)) {
                throw new B1Exception('B1_ERR_KEY_SYNTAX', (string) $k);
            }
            $parts[] = b1_escape((string) $k) . ':' . b1_canonicalize($v->members[$k], $depth + 1);
        }
        return '{' . implode(',', $parts) . '}';
    }
    throw new B1Exception('B1_ERR_PARSE', 'unsupported value type');
}

function b1_digest_value(mixed $v): string
{
    return hash('sha256', b1_canonicalize($v));
}

function b1_digest_text(string $text): string
{
    return b1_digest_value((new B1Parser($text))->parse());
}
