/*
 * Tests for the normative kernel: SHA-256 against published vectors, canonicalization against
 * hand-computed expectations, and the frame signature's behavioural properties.
 *
 * The SHA-256 vectors matter more than they look: every digest in the system rests on this
 * function, and "our two implementations agree" would prove nothing if both were wrong. These are
 * FIPS 180-4 / RFC 6234 published values, so agreement here is agreement with the outside world.
 */

#include "b1_abi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static void check_str(const char *what, const char *got, const char *want)
{
    if (strcmp(got, want) == 0) {
        printf("  ok    %s\n", what);
    } else {
        printf("  FAIL  %s\n        got  %s\n        want %s\n", what, got, want);
        failures++;
    }
}

static void check_u32(const char *what, uint32_t got, uint32_t want)
{
    if (got == want) {
        printf("  ok    %s (%u)\n", what, got);
    } else {
        printf("  FAIL  %s: got %u want %u\n", what, got, want);
        failures++;
    }
}

static void check_true(const char *what, int cond)
{
    if (cond) printf("  ok    %s\n", what);
    else { printf("  FAIL  %s\n", what); failures++; }
}

static void sha_hex(const char *msg, char out[65])
{
    uint8_t h[32];
    b1_sha256((const uint8_t *)msg, strlen(msg), h);
    b1_hex(h, 32, out);
}

static void test_sha256(void)
{
    printf("sha256 (published vectors)\n");
    char hex[65];

    sha_hex("", hex);
    check_str("empty string",
              hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

    sha_hex("abc", hex);
    check_str("\"abc\"",
              hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

    sha_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", hex);
    check_str("448-bit message",
              hex, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");

    /* Exercises the two-block padding path: 56 bytes leaves no room for the length field. */
    char m56[57];
    memset(m56, 'a', 56);
    m56[56] = '\0';
    sha_hex(m56, hex);
    check_str("56 'a' (two-block padding)",
              hex, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a");

    /* One million 'a' — the classic long-message vector. */
    {
        size_t n = 1000000;
        char *big = (char *)malloc(n);
        memset(big, 'a', n);
        uint8_t h[32];
        b1_sha256((const uint8_t *)big, n, h);
        b1_hex(h, 32, hex);
        free(big);
        check_str("one million 'a'",
                  hex, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    }
}

static void digest_of(const char *json, char out[65], b1_status *st)
{
    *st = b1_digest(json, strlen(json), out);
    if (*st != B1_OK) snprintf(out, 65, "%s", b1_status_token(*st));
}

static void test_canon(void)
{
    printf("b1-canon-1\n");
    char hex[65];
    b1_status st;

    /* SHA-256("{}") and SHA-256("[]") — externally checkable. */
    digest_of("{}", hex, &st);
    check_str("{} digest",
              hex, "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a");
    digest_of("[]", hex, &st);
    check_str("[] digest",
              hex, "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945");

    /* Key order and whitespace must not affect the digest. */
    char a[65], b[65];
    digest_of("{\"b\":1,\"a\":2}", a, &st);
    digest_of("  { \"a\" : 2 , \"b\" : 1 }  ", b, &st);
    check_true("member order and whitespace are irrelevant", strcmp(a, b) == 0);

    /* An escaped surrogate pair and the literal character are the same document. */
    digest_of("{\"x\":\"\\ud83c\\udfac\"}", a, &st);
    digest_of("{\"x\":\"\xf0\x9f\x8e\xac\"}", b, &st);
    check_true("escaped surrogate pair == literal astral character", strcmp(a, b) == 0);

    /* Rejections. */
    struct { const char *doc; b1_status want; const char *what; } neg[] = {
        { "{\"a\":1.5}",            B1_ERR_NONINTEGER_NUMBER, "float rejected" },
        { "{\"a\":1e3}",            B1_ERR_NONINTEGER_NUMBER, "exponent rejected" },
        { "{\"a\":9007199254740992}", B1_ERR_NONINTEGER_NUMBER, "2^53 rejected" },
        { "{\"a\":-0}",             B1_ERR_NONINTEGER_NUMBER, "negative zero rejected" },
        { "{\"a\":01}",             B1_ERR_PARSE,             "leading zero rejected" },
        { "{\"a b\":1}",            B1_ERR_KEY_SYNTAX,        "key with space rejected" },
        { "{\"\":1}",               B1_ERR_KEY_SYNTAX,        "empty key rejected" },
        { "{\"a\":1,\"a\":2}",      B1_ERR_DUPLICATE_KEY,     "duplicate key rejected" },
        { "{\"a\":\"\\ud83c\"}",    B1_ERR_INVALID_UTF8,      "lone high surrogate rejected" },
        { "{\"a\":\"\\udfac\"}",    B1_ERR_INVALID_UTF8,      "lone low surrogate rejected" },
        { "{\"a\":\"\xc3\x28\"}",   B1_ERR_INVALID_UTF8,      "malformed utf-8 rejected" },
        { "{\"a\":1} {\"b\":2}",    B1_ERR_PARSE,             "trailing input rejected" },
        { "{\"a\":\"x",             B1_ERR_PARSE,             "unterminated string rejected" },
    };
    for (size_t i = 0; i < sizeof(neg) / sizeof(neg[0]); i++) {
        char h[65];
        b1_status s;
        digest_of(neg[i].doc, h, &s);
        if (s == neg[i].want) printf("  ok    %s\n", neg[i].what);
        else {
            printf("  FAIL  %s: got %s want %s\n", neg[i].what,
                   b1_status_token(s), b1_status_token(neg[i].want));
            failures++;
        }
    }

    /* Depth: 64 nested arrays are legal, 70 are not. */
    {
        char deep[256];
        size_t k = 0;
        for (int i = 0; i < 60; i++) deep[k++] = '[';
        deep[k++] = '1';
        for (int i = 0; i < 60; i++) deep[k++] = ']';
        deep[k] = '\0';
        b1_status s;
        char h[65];
        digest_of(deep, h, &s);
        check_true("60 levels accepted", s == B1_OK);
    }
    {
        char deep[256];
        size_t k = 0;
        for (int i = 0; i < 70; i++) deep[k++] = '[';
        deep[k++] = '1';
        for (int i = 0; i < 70; i++) deep[k++] = ']';
        deep[k] = '\0';
        b1_status s;
        char h[65];
        digest_of(deep, h, &s);
        check_true("70 levels rejected", s == B1_ERR_DEPTH);
    }
}

/* Synthesizes a frame: a vertical gradient with a bright block whose position shifts. */
static uint8_t *make_frame(uint32_t w, uint32_t h, uint32_t block_x, uint8_t bias)
{
    uint8_t *rgb = (uint8_t *)malloc((size_t)w * h * 3);
    for (uint32_t y = 0; y < h; y++) {
        for (uint32_t x = 0; x < w; x++) {
            size_t o = ((size_t)y * w + x) * 3;
            uint32_t v = (y * 200u / h) + bias;
            if (v > 255) v = 255;
            int in_block = (x >= block_x && x < block_x + w / 8 && y > h / 3 && y < 2 * h / 3);
            uint8_t c = in_block ? 250 : (uint8_t)v;
            rgb[o] = rgb[o + 1] = rgb[o + 2] = c;
        }
    }
    return rgb;
}

static void test_signature(void)
{
    printf("frame signature\n");
    const uint32_t w = 160, h = 90;

    uint8_t *f1 = make_frame(w, h, 20, 0);
    uint8_t *f2 = make_frame(w, h, 20, 0);   /* identical */
    uint8_t *f3 = make_frame(w, h, 100, 0);  /* block moved: structural change */
    uint8_t *f4 = make_frame(w, h, 20, 30);  /* exposure lifted: tonal change only */

    b1_signature s1, s2, s3, s4;
    check_true("signature computed", b1_frame_signature(f1, w, h, &s1) == B1_OK);
    b1_frame_signature(f2, w, h, &s2);
    b1_frame_signature(f3, w, h, &s3);
    b1_frame_signature(f4, w, h, &s4);

    check_str("identical frames share a digest", s1.digest_hex, s2.digest_hex);
    check_u32("identical frames have distance 0", b1_signature_distance(&s1, &s2), 0);

    uint32_t moved = b1_signature_distance(&s1, &s3);
    uint32_t exposed = b1_signature_distance(&s1, &s4);
    check_true("moving a block registers as change", moved > 0);
    check_true("structural change outweighs exposure change", moved > exposed);
    printf("        moved=%u exposed=%u (milli-units)\n", moved, exposed);

    check_true("degenerate input rejected", b1_frame_signature(f1, 0, h, &s1) == B1_ERR_RANGE);

    free(f1); free(f2); free(f3); free(f4);
}

int main(void)
{
    test_sha256();
    test_canon();
    test_signature();

    printf("\n%s: %d failure(s)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
