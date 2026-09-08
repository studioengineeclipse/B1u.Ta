/*
 * B1-CANON-1 strict parser and canonical serializer.
 * Normative implementation. See SPEC/20-b1-canon-1.md.
 *
 * A strict parser is written here rather than borrowing one because the profile's guarantees are
 * mostly *rejections*: duplicate member names, non-integer numbers, non-ASCII keys and unpaired
 * surrogates must all fail loudly. A permissive parser that silently repairs any of these produces
 * a digest no other implementation reproduces, turning a loud failure into a silent divergence.
 *
 * Strings are length-delimited rather than NUL-terminated because \\u0000 is a legal escape and
 * must survive parsing intact.
 */

#include "b1_abi.h"
#include <stdlib.h>
#include <string.h>

#define MAX_DEPTH 64
#define MAX_SAFE 9007199254740991LL

typedef enum { V_NULL, V_BOOL, V_INT, V_STR, V_ARR, V_OBJ } vkind;

typedef struct { char *p; size_t n; } bstr;

typedef struct b1v b1v;
struct b1v {
    vkind k;
    int boolean;
    int64_t integer;
    bstr str;
    struct { b1v **items; size_t n, cap; } arr;
    struct { bstr *keys; b1v **vals; size_t n, cap; } obj;
};

typedef struct {
    const char *s;
    size_t n, i;
    b1_status err;
} P;

/* --- value lifecycle -------------------------------------------------------- */

static b1v *v_new(vkind k)
{
    b1v *v = (b1v *)calloc(1, sizeof(b1v));
    if (v) v->k = k;
    return v;
}

static void v_free(b1v *v)
{
    if (!v) return;
    switch (v->k) {
    case V_STR:
        free(v->str.p);
        break;
    case V_ARR:
        for (size_t i = 0; i < v->arr.n; i++) v_free(v->arr.items[i]);
        free(v->arr.items);
        break;
    case V_OBJ:
        for (size_t i = 0; i < v->obj.n; i++) {
            free(v->obj.keys[i].p);
            v_free(v->obj.vals[i]);
        }
        free(v->obj.keys);
        free(v->obj.vals);
        break;
    default:
        break;
    }
    free(v);
}

/* --- growable byte buffer --------------------------------------------------- */

typedef struct { char *p; size_t n, cap; } buf;

static int buf_reserve(buf *b, size_t extra)
{
    if (b->n + extra + 1 <= b->cap) return 1;
    size_t cap = b->cap ? b->cap : 256;
    while (cap < b->n + extra + 1) cap *= 2;
    char *p = (char *)realloc(b->p, cap);
    if (!p) return 0;
    b->p = p;
    b->cap = cap;
    return 1;
}

static int buf_put(buf *b, const char *data, size_t len)
{
    if (!buf_reserve(b, len)) return 0;
    memcpy(b->p + b->n, data, len);
    b->n += len;
    b->p[b->n] = '\0';
    return 1;
}

static int buf_putc(buf *b, char c) { return buf_put(b, &c, 1); }

/* --- UTF-8 ------------------------------------------------------------------ */

/* Appends the UTF-8 encoding of a scalar value. Surrogates are never passed in. */
static int utf8_put(buf *b, uint32_t cp)
{
    char tmp[4];
    if (cp < 0x80) {
        tmp[0] = (char)cp;
        return buf_put(b, tmp, 1);
    }
    if (cp < 0x800) {
        tmp[0] = (char)(0xC0 | (cp >> 6));
        tmp[1] = (char)(0x80 | (cp & 0x3F));
        return buf_put(b, tmp, 2);
    }
    if (cp < 0x10000) {
        tmp[0] = (char)(0xE0 | (cp >> 12));
        tmp[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        tmp[2] = (char)(0x80 | (cp & 0x3F));
        return buf_put(b, tmp, 3);
    }
    tmp[0] = (char)(0xF0 | (cp >> 18));
    tmp[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    tmp[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    tmp[3] = (char)(0x80 | (cp & 0x3F));
    return buf_put(b, tmp, 4);
}

/*
 * Validates one UTF-8 sequence starting at s[i], returning its length or 0 if malformed.
 * Rejects overlong encodings, surrogates encoded as UTF-8, and scalars above U+10FFFF — all of
 * which are ways to smuggle two byte sequences that decode to the same text.
 */
static size_t utf8_len(const unsigned char *s, size_t avail)
{
    unsigned char c = s[0];
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) {
        if (avail < 2 || (s[1] & 0xC0) != 0x80) return 0;
        if (c < 0xC2) return 0; /* overlong */
        return 2;
    }
    if ((c & 0xF0) == 0xE0) {
        if (avail < 3 || (s[1] & 0xC0) != 0x80 || (s[2] & 0xC0) != 0x80) return 0;
        if (c == 0xE0 && s[1] < 0xA0) return 0;                 /* overlong */
        if (c == 0xED && s[1] >= 0xA0) return 0;                /* surrogate */
        return 3;
    }
    if ((c & 0xF8) == 0xF0) {
        if (avail < 4 || (s[1] & 0xC0) != 0x80 || (s[2] & 0xC0) != 0x80 || (s[3] & 0xC0) != 0x80)
            return 0;
        if (c == 0xF0 && s[1] < 0x90) return 0;                 /* overlong */
        if (c > 0xF4 || (c == 0xF4 && s[1] >= 0x90)) return 0;   /* > U+10FFFF */
        return 4;
    }
    return 0;
}

/* --- parser ----------------------------------------------------------------- */

static b1v *p_value(P *p, int depth);

static void p_ws(P *p)
{
    while (p->i < p->n) {
        char c = p->s[p->i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') p->i++;
        else break;
    }
}

static int p_lit(P *p, const char *word)
{
    size_t len = strlen(word);
    if (p->i + len <= p->n && memcmp(p->s + p->i, word, len) == 0) {
        p->i += len;
        return 1;
    }
    p->err = B1_ERR_PARSE;
    return 0;
}

static int hex4(P *p, uint32_t *out)
{
    if (p->i + 4 > p->n) { p->err = B1_ERR_PARSE; return 0; }
    uint32_t v = 0;
    for (size_t k = 0; k < 4; k++) {
        char c = p->s[p->i + k];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= (uint32_t)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (uint32_t)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (uint32_t)(c - 'A' + 10);
        else { p->err = B1_ERR_PARSE; return 0; }
    }
    p->i += 4;
    *out = v;
    return 1;
}

/* Parses a string literal into decoded UTF-8 bytes. */
static int p_string(P *p, bstr *out)
{
    p->i++; /* opening quote */
    buf b = {0};

    for (;;) {
        if (p->i >= p->n) { p->err = B1_ERR_PARSE; goto fail; }
        unsigned char c = (unsigned char)p->s[p->i];

        if (c == '"') {
            p->i++;
            if (!b.p && !buf_reserve(&b, 0)) { p->err = B1_ERR_NOMEM; goto fail; }
            out->p = b.p;
            out->n = b.n;
            return 1;
        }

        if (c == '\\') {
            p->i++;
            if (p->i >= p->n) { p->err = B1_ERR_PARSE; goto fail; }
            char e = p->s[p->i++];
            int ok = 1;
            switch (e) {
            case '"':  ok = buf_putc(&b, '"');  break;
            case '\\': ok = buf_putc(&b, '\\'); break;
            case '/':  ok = buf_putc(&b, '/');  break;
            case 'b':  ok = buf_putc(&b, '\b'); break;
            case 'f':  ok = buf_putc(&b, '\f'); break;
            case 'n':  ok = buf_putc(&b, '\n'); break;
            case 'r':  ok = buf_putc(&b, '\r'); break;
            case 't':  ok = buf_putc(&b, '\t'); break;
            case 'u': {
                uint32_t cp;
                if (!hex4(p, &cp)) goto fail;
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    /* High surrogate: a low surrogate escape must follow, and the pair joins. */
                    if (p->i + 2 > p->n || p->s[p->i] != '\\' || p->s[p->i + 1] != 'u') {
                        p->err = B1_ERR_INVALID_UTF8; goto fail;
                    }
                    p->i += 2;
                    uint32_t low;
                    if (!hex4(p, &low)) goto fail;
                    if (low < 0xDC00 || low > 0xDFFF) { p->err = B1_ERR_INVALID_UTF8; goto fail; }
                    cp = 0x10000u + ((cp - 0xD800u) << 10) + (low - 0xDC00u);
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    p->err = B1_ERR_INVALID_UTF8; goto fail;
                }
                ok = utf8_put(&b, cp);
                break;
            }
            default:
                p->err = B1_ERR_PARSE; goto fail;
            }
            if (!ok) { p->err = B1_ERR_NOMEM; goto fail; }
            continue;
        }

        if (c < 0x20) { p->err = B1_ERR_PARSE; goto fail; } /* raw control character */

        size_t len = utf8_len((const unsigned char *)p->s + p->i, p->n - p->i);
        if (len == 0) { p->err = B1_ERR_INVALID_UTF8; goto fail; }
        if (!buf_put(&b, p->s + p->i, len)) { p->err = B1_ERR_NOMEM; goto fail; }
        p->i += len;
    }

fail:
    free(b.p);
    return 0;
}

static int p_number(P *p, int64_t *out)
{
    size_t start = p->i;
    if (p->s[p->i] == '-') p->i++;
    size_t digits_start = p->i;
    while (p->i < p->n && p->s[p->i] >= '0' && p->s[p->i] <= '9') p->i++;
    if (p->i == digits_start) { p->err = B1_ERR_PARSE; return 0; }
    if (p->i - digits_start > 1 && p->s[digits_start] == '0') { p->err = B1_ERR_PARSE; return 0; }

    if (p->i < p->n) {
        char c = p->s[p->i];
        if (c == '.' || c == 'e' || c == 'E') { p->err = B1_ERR_NONINTEGER_NUMBER; return 0; }
    }

    int negative = (p->s[start] == '-');
    if (negative && p->i - digits_start == 1 && p->s[digits_start] == '0') {
        p->err = B1_ERR_NONINTEGER_NUMBER; /* -0 */
        return 0;
    }

    /* Accumulate with an explicit bound so overflow becomes a reported range error, not UB. */
    uint64_t mag = 0;
    for (size_t k = digits_start; k < p->i; k++) {
        if (mag > (uint64_t)MAX_SAFE / 10) { p->err = B1_ERR_NONINTEGER_NUMBER; return 0; }
        mag = mag * 10 + (uint64_t)(p->s[k] - '0');
        if (mag > (uint64_t)MAX_SAFE) { p->err = B1_ERR_NONINTEGER_NUMBER; return 0; }
    }

    *out = negative ? -(int64_t)mag : (int64_t)mag;
    return 1;
}

static int key_syntax_ok(const bstr *k)
{
    if (k->n < 1 || k->n > 64) return 0;
    for (size_t i = 0; i < k->n; i++) {
        char c = k->p[i];
        int ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                 c == '_' || c == '$' || c == '.' || c == '-';
        if (!ok) return 0;
    }
    return 1;
}

static int bstr_cmp(const bstr *a, const bstr *b)
{
    size_t m = a->n < b->n ? a->n : b->n;
    int c = memcmp(a->p, b->p, m);
    if (c != 0) return c;
    return (a->n < b->n) ? -1 : (a->n > b->n) ? 1 : 0;
}

static b1v *p_object(P *p, int depth)
{
    p->i++; /* { */
    b1v *v = v_new(V_OBJ);
    if (!v) { p->err = B1_ERR_NOMEM; return NULL; }

    p_ws(p);
    if (p->i < p->n && p->s[p->i] == '}') { p->i++; return v; }

    for (;;) {
        p_ws(p);
        if (p->i >= p->n || p->s[p->i] != '"') { p->err = B1_ERR_PARSE; goto fail; }

        bstr key;
        if (!p_string(p, &key)) goto fail;
        if (!key_syntax_ok(&key)) { free(key.p); p->err = B1_ERR_KEY_SYNTAX; goto fail; }
        for (size_t i = 0; i < v->obj.n; i++) {
            if (bstr_cmp(&v->obj.keys[i], &key) == 0) {
                free(key.p);
                p->err = B1_ERR_DUPLICATE_KEY;
                goto fail;
            }
        }

        p_ws(p);
        if (p->i >= p->n || p->s[p->i] != ':') { free(key.p); p->err = B1_ERR_PARSE; goto fail; }
        p->i++;
        p_ws(p);

        b1v *child = p_value(p, depth + 1);
        if (!child) { free(key.p); goto fail; }

        if (v->obj.n == v->obj.cap) {
            size_t cap = v->obj.cap ? v->obj.cap * 2 : 8;
            bstr *nk = (bstr *)realloc(v->obj.keys, cap * sizeof(bstr));
            b1v **nv = (b1v **)realloc(v->obj.vals, cap * sizeof(b1v *));
            if (!nk || !nv) {
                if (nk) v->obj.keys = nk;
                if (nv) v->obj.vals = nv;
                free(key.p); v_free(child);
                p->err = B1_ERR_NOMEM; goto fail;
            }
            v->obj.keys = nk;
            v->obj.vals = nv;
            v->obj.cap = cap;
        }
        v->obj.keys[v->obj.n] = key;
        v->obj.vals[v->obj.n] = child;
        v->obj.n++;

        p_ws(p);
        if (p->i >= p->n) { p->err = B1_ERR_PARSE; goto fail; }
        if (p->s[p->i] == ',') { p->i++; continue; }
        if (p->s[p->i] == '}') { p->i++; return v; }
        p->err = B1_ERR_PARSE;
        goto fail;
    }

fail:
    v_free(v);
    return NULL;
}

static b1v *p_array(P *p, int depth)
{
    p->i++; /* [ */
    b1v *v = v_new(V_ARR);
    if (!v) { p->err = B1_ERR_NOMEM; return NULL; }

    p_ws(p);
    if (p->i < p->n && p->s[p->i] == ']') { p->i++; return v; }

    for (;;) {
        p_ws(p);
        b1v *child = p_value(p, depth + 1);
        if (!child) goto fail;

        if (v->arr.n == v->arr.cap) {
            size_t cap = v->arr.cap ? v->arr.cap * 2 : 8;
            b1v **items = (b1v **)realloc(v->arr.items, cap * sizeof(b1v *));
            if (!items) { v_free(child); p->err = B1_ERR_NOMEM; goto fail; }
            v->arr.items = items;
            v->arr.cap = cap;
        }
        v->arr.items[v->arr.n++] = child;

        p_ws(p);
        if (p->i >= p->n) { p->err = B1_ERR_PARSE; goto fail; }
        if (p->s[p->i] == ',') { p->i++; continue; }
        if (p->s[p->i] == ']') { p->i++; return v; }
        p->err = B1_ERR_PARSE;
        goto fail;
    }

fail:
    v_free(v);
    return NULL;
}

static b1v *p_value(P *p, int depth)
{
    if (depth > MAX_DEPTH) { p->err = B1_ERR_DEPTH; return NULL; }
    if (p->i >= p->n) { p->err = B1_ERR_PARSE; return NULL; }

    char c = p->s[p->i];
    if (c == '{') return p_object(p, depth);
    if (c == '[') return p_array(p, depth);

    if (c == '"') {
        b1v *v = v_new(V_STR);
        if (!v) { p->err = B1_ERR_NOMEM; return NULL; }
        if (!p_string(p, &v->str)) { free(v); return NULL; }
        return v;
    }
    if (c == 't' || c == 'f') {
        b1v *v = v_new(V_BOOL);
        if (!v) { p->err = B1_ERR_NOMEM; return NULL; }
        if (!p_lit(p, c == 't' ? "true" : "false")) { free(v); return NULL; }
        v->boolean = (c == 't');
        return v;
    }
    if (c == 'n') {
        b1v *v = v_new(V_NULL);
        if (!v) { p->err = B1_ERR_NOMEM; return NULL; }
        if (!p_lit(p, "null")) { free(v); return NULL; }
        return v;
    }
    if (c == '-' || (c >= '0' && c <= '9')) {
        b1v *v = v_new(V_INT);
        if (!v) { p->err = B1_ERR_NOMEM; return NULL; }
        if (!p_number(p, &v->integer)) { free(v); return NULL; }
        return v;
    }

    p->err = B1_ERR_PARSE;
    return NULL;
}

/* --- emitter ---------------------------------------------------------------- */

static int emit_string(buf *b, const bstr *s)
{
    if (!buf_putc(b, '"')) return 0;
    for (size_t i = 0; i < s->n; i++) {
        unsigned char c = (unsigned char)s->p[i];
        switch (c) {
        case '"':  if (!buf_put(b, "\\\"", 2)) return 0; continue;
        case '\\': if (!buf_put(b, "\\\\", 2)) return 0; continue;
        case '\b': if (!buf_put(b, "\\b", 2)) return 0; continue;
        case '\t': if (!buf_put(b, "\\t", 2)) return 0; continue;
        case '\n': if (!buf_put(b, "\\n", 2)) return 0; continue;
        case '\f': if (!buf_put(b, "\\f", 2)) return 0; continue;
        case '\r': if (!buf_put(b, "\\r", 2)) return 0; continue;
        default: break;
        }
        if (c < 0x20) {
            static const char digits[] = "0123456789abcdef"; /* lowercase, per R3 */
            char esc[6] = { '\\', 'u', '0', '0', digits[c >> 4], digits[c & 0x0f] };
            if (!buf_put(b, esc, 6)) return 0;
            continue;
        }
        if (!buf_putc(b, (char)c)) return 0;
    }
    return buf_putc(b, '"');
}

static int emit_int(buf *b, int64_t v)
{
    char tmp[24];
    int n = 0;
    int negative = v < 0;
    uint64_t mag = negative ? (uint64_t)(-(v + 1)) + 1 : (uint64_t)v;
    do { tmp[n++] = (char)('0' + (mag % 10)); mag /= 10; } while (mag);
    if (negative) tmp[n++] = '-';
    char out[24];
    for (int k = 0; k < n; k++) out[k] = tmp[n - 1 - k];
    return buf_put(b, out, (size_t)n);
}

/*
 * Members are sorted through a local array of (key, value) pairs rather than an index permutation
 * with a shared comparison context: the comparator then needs no global, so canonicalization is
 * reentrant and safe to call from several threads. Emission does not mutate the parsed value.
 */
typedef struct { const bstr *key; const b1v *val; } member;

static int member_cmp(const void *a, const void *b)
{
    return bstr_cmp(((const member *)a)->key, ((const member *)b)->key);
}

static b1_status emit(buf *b, const b1v *v, int depth)
{
    if (depth > MAX_DEPTH) return B1_ERR_DEPTH;

    switch (v->k) {
    case V_NULL:
        return buf_put(b, "null", 4) ? B1_OK : B1_ERR_NOMEM;
    case V_BOOL:
        return buf_put(b, v->boolean ? "true" : "false", v->boolean ? 4 : 5) ? B1_OK : B1_ERR_NOMEM;
    case V_INT:
        return emit_int(b, v->integer) ? B1_OK : B1_ERR_NOMEM;
    case V_STR:
        return emit_string(b, &v->str) ? B1_OK : B1_ERR_NOMEM;
    case V_ARR: {
        if (!buf_putc(b, '[')) return B1_ERR_NOMEM;
        for (size_t i = 0; i < v->arr.n; i++) {
            if (i && !buf_putc(b, ',')) return B1_ERR_NOMEM;
            b1_status st = emit(b, v->arr.items[i], depth + 1);
            if (st != B1_OK) return st;
        }
        return buf_putc(b, ']') ? B1_OK : B1_ERR_NOMEM;
    }
    case V_OBJ: {
        member *members = NULL;
        if (v->obj.n) {
            members = (member *)malloc(v->obj.n * sizeof(member));
            if (!members) return B1_ERR_NOMEM;
            for (size_t i = 0; i < v->obj.n; i++) {
                members[i].key = &v->obj.keys[i];
                members[i].val = v->obj.vals[i];
            }
            /* Keys are ASCII (R2), so byte order is the required order. */
            qsort(members, v->obj.n, sizeof(member), member_cmp);
        }
        if (!buf_putc(b, '{')) { free(members); return B1_ERR_NOMEM; }
        for (size_t i = 0; i < v->obj.n; i++) {
            if (i && !buf_putc(b, ',')) { free(members); return B1_ERR_NOMEM; }
            if (!emit_string(b, members[i].key)) { free(members); return B1_ERR_NOMEM; }
            if (!buf_putc(b, ':')) { free(members); return B1_ERR_NOMEM; }
            b1_status st = emit(b, members[i].val, depth + 1);
            if (st != B1_OK) { free(members); return st; }
        }
        free(members);
        return buf_putc(b, '}') ? B1_OK : B1_ERR_NOMEM;
    }
    }
    return B1_ERR_PARSE;
}

/* --- public ----------------------------------------------------------------- */

b1_status b1_canonicalize(const char *json, size_t len, char **out, size_t *out_len)
{
    *out = NULL;
    if (out_len) *out_len = 0;

    P p = { json, len, 0, B1_OK };
    p_ws(&p);
    b1v *v = p_value(&p, 0);
    if (!v) return p.err ? p.err : B1_ERR_PARSE;

    p_ws(&p);
    if (p.i != p.n) { v_free(v); return B1_ERR_PARSE; } /* trailing input */

    buf b = {0};
    b1_status st = emit(&b, v, 0);
    v_free(v);
    if (st != B1_OK) { free(b.p); return st; }

    if (!b.p && !buf_reserve(&b, 0)) return B1_ERR_NOMEM;
    *out = b.p;
    if (out_len) *out_len = b.n;
    return B1_OK;
}

b1_status b1_digest(const char *json, size_t len, char out_hex[65])
{
    char *canon = NULL;
    size_t canon_len = 0;
    b1_status st = b1_canonicalize(json, len, &canon, &canon_len);
    if (st != B1_OK) return st;

    uint8_t hash[32];
    b1_sha256((const uint8_t *)canon, canon_len, hash);
    b1_hex(hash, 32, out_hex);
    free(canon);
    return B1_OK;
}

void b1_free(void *p) { free(p); }
