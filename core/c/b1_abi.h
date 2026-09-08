/*
 * b1_abi.h — the language-neutral binary contract (IF-2).
 *
 * C owns the normative kernel: SHA-256, B1-CANON-1 canonicalization, and the frame visual
 * signature. Where any other implementation disagrees with this one on a legal document, the
 * other implementation is wrong by definition (SPEC/20-b1-canon-1.md §3).
 *
 * Stability: symbols are versioned by the B1_ABI_VERSION macro. Ownership of every returned
 * buffer is stated explicitly; nothing is returned that the caller is not told how to free.
 */

#ifndef B1_ABI_H
#define B1_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define B1_ABI_VERSION 1

/* Status codes. The token strings are the values the conform protocol prints on stderr. */
typedef enum {
    B1_OK = 0,
    B1_ERR_PARSE = 1,
    B1_ERR_NONINTEGER_NUMBER = 2,
    B1_ERR_KEY_SYNTAX = 3,
    B1_ERR_DUPLICATE_KEY = 4,
    B1_ERR_INVALID_UTF8 = 5,
    B1_ERR_DEPTH = 6,
    B1_ERR_NOMEM = 7,
    B1_ERR_RANGE = 8
} b1_status;

/* Returns the stable token string, e.g. "B1_ERR_DUPLICATE_KEY". Never NULL; static storage. */
const char *b1_status_token(b1_status status);

/* --- SHA-256 --------------------------------------------------------------- */

void b1_sha256(const uint8_t *data, size_t len, uint8_t out[32]);

/* Writes 2*len lowercase hex digits plus a NUL. `out` must hold 2*len+1 bytes. */
void b1_hex(const uint8_t *bytes, size_t len, char *out);

/* --- B1-CANON-1 ------------------------------------------------------------ */

/*
 * Canonicalizes `json` (length `len`) per SPEC/20-b1-canon-1.md.
 * On B1_OK, *out is a NUL-terminated malloc'd buffer owned by the caller: free with b1_free.
 * *out_len receives the byte length excluding the NUL. On error *out is set to NULL.
 */
b1_status b1_canonicalize(const char *json, size_t len, char **out, size_t *out_len);

/* Canonicalizes then hashes. `out_hex` receives 64 lowercase hex digits plus a NUL. */
b1_status b1_digest(const char *json, size_t len, char out_hex[65]);

void b1_free(void *p);

/* --- Frame visual signature ------------------------------------------------ */

/*
 * The perceptual signature of a single frame, used for continuity comparison
 * (SPEC/60-continuity.md §2, final_frame_visual_signature).
 *
 * Two components, kept separate on purpose:
 *   dhash  a 64-bit difference hash — cheap, robust to small luma shifts
 *   grid   a 4x4 spatial x 8 luma-bucket histogram in parts-per-million
 *
 * digest_hex is the B1-CANON-1 digest of a canonical document built from both, so the signature
 * is itself expressible in the shared contract and any language can verify it without needing to
 * reimplement the pixel arithmetic.
 */
typedef struct {
    uint64_t dhash;
    uint32_t grid[16 * 8];
    uint32_t width_px;
    uint32_t height_px;
    char digest_hex[65];
} b1_signature;

/*
 * `rgb` is width*height*3 bytes, 8 bits per channel, row-major, no padding.
 * Fails with B1_ERR_RANGE if width or height is zero.
 */
b1_status b1_frame_signature(const uint8_t *rgb, uint32_t width, uint32_t height,
                             b1_signature *out);

/*
 * Perceptual distance in milli-units, 0 (identical) to 1000 (maximally different).
 *
 * This is a PROXY (SPEC/50-quality-vector.md §6). A small distance says the frames are
 * structurally similar; it does not say the subject is the same person. Callers must record it
 * with measurement_basis PROXY rather than treating it as semantic identity.
 */
uint32_t b1_signature_distance(const b1_signature *a, const b1_signature *b);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* B1_ABI_H */
