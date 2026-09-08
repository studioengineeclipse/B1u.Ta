/*
 * Frame visual signature (SPEC/60-continuity.md §2).
 *
 * Two independent components, deliberately not blended into one number:
 *
 *   dhash  a 64-bit difference hash over a 9x8 luma downscale. Robust to small global luma
 *          shifts, sensitive to structural change.
 *   grid   a 4x4 spatial by 8 luma-bucket histogram in parts-per-million. Catches redistribution
 *          of tone across the frame that a difference hash alone is blind to.
 *
 * Keeping them separate matters for continuity: two frames can share a dhash while differing in
 * where their tone sits, and averaging the two measures early would hide that.
 *
 * This is a PROXY. It says whether two frames are structurally similar. It cannot say whether the
 * subject is the same person, and callers must record it with measurement_basis PROXY.
 */

#include "b1_abi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Rec. 601 luma in fixed point: no floating point anywhere in a digest-bearing path. */
static inline uint32_t luma(const uint8_t *px)
{
    return (299u * px[0] + 587u * px[1] + 114u * px[2]) / 1000u;
}

/* Box-samples the source into a dst_w x dst_h luma grid. */
static void downscale(const uint8_t *rgb, uint32_t w, uint32_t h,
                      uint32_t *dst, uint32_t dst_w, uint32_t dst_h)
{
    for (uint32_t by = 0; by < dst_h; by++) {
        uint32_t y0 = (uint32_t)((uint64_t)by * h / dst_h);
        uint32_t y1 = (uint32_t)((uint64_t)(by + 1) * h / dst_h);
        if (y1 <= y0) y1 = y0 + 1;
        if (y1 > h) y1 = h;

        for (uint32_t bx = 0; bx < dst_w; bx++) {
            uint32_t x0 = (uint32_t)((uint64_t)bx * w / dst_w);
            uint32_t x1 = (uint32_t)((uint64_t)(bx + 1) * w / dst_w);
            if (x1 <= x0) x1 = x0 + 1;
            if (x1 > w) x1 = w;

            uint64_t sum = 0;
            uint64_t count = 0;
            for (uint32_t y = y0; y < y1; y++) {
                for (uint32_t x = x0; x < x1; x++) {
                    sum += luma(rgb + ((size_t)y * w + x) * 3);
                    count++;
                }
            }
            dst[by * dst_w + bx] = count ? (uint32_t)(sum / count) : 0;
        }
    }
}

b1_status b1_frame_signature(const uint8_t *rgb, uint32_t width, uint32_t height,
                             b1_signature *out)
{
    if (!rgb || !out || width == 0 || height == 0) return B1_ERR_RANGE;

    memset(out, 0, sizeof(*out));
    out->width_px = width;
    out->height_px = height;

    /* dhash: 9x8 downscale, then compare horizontally adjacent cells. */
    uint32_t small[9 * 8];
    downscale(rgb, width, height, small, 9, 8);

    uint64_t dhash = 0;
    int bit = 0;
    for (uint32_t y = 0; y < 8; y++) {
        for (uint32_t x = 0; x < 8; x++) {
            if (small[y * 9 + x] < small[y * 9 + x + 1]) dhash |= (uint64_t)1 << bit;
            bit++;
        }
    }
    out->dhash = dhash;

    /* grid: 4x4 spatial blocks, 8 luma buckets each, normalized to ppm within the block. */
    for (uint32_t by = 0; by < 4; by++) {
        uint32_t y0 = (uint32_t)((uint64_t)by * height / 4);
        uint32_t y1 = (uint32_t)((uint64_t)(by + 1) * height / 4);
        if (y1 <= y0) y1 = y0 + 1;
        if (y1 > height) y1 = height;

        for (uint32_t bx = 0; bx < 4; bx++) {
            uint32_t x0 = (uint32_t)((uint64_t)bx * width / 4);
            uint32_t x1 = (uint32_t)((uint64_t)(bx + 1) * width / 4);
            if (x1 <= x0) x1 = x0 + 1;
            if (x1 > width) x1 = width;

            uint64_t bucket[8] = {0};
            uint64_t total = 0;
            for (uint32_t y = y0; y < y1; y++) {
                for (uint32_t x = x0; x < x1; x++) {
                    uint32_t l = luma(rgb + ((size_t)y * width + x) * 3);
                    uint32_t b = l >> 5; /* 0..255 -> 0..7 */
                    if (b > 7) b = 7;
                    bucket[b]++;
                    total++;
                }
            }
            uint32_t base = (by * 4 + bx) * 8;
            for (uint32_t k = 0; k < 8; k++) {
                out->grid[base + k] = total ? (uint32_t)(bucket[k] * 1000000u / total) : 0u;
            }
        }
    }

    /*
     * The signature digest is the B1-CANON-1 digest of a canonical document built from both
     * components. Expressing it in the shared contract means any of the fourteen languages can
     * verify a signature without reimplementing the pixel arithmetic.
     */
    size_t cap = 4096;
    char *doc = (char *)malloc(cap);
    if (!doc) return B1_ERR_NOMEM;

    int n = snprintf(doc, cap, "{\"dhash\":\"%016llx\",\"grid\":[",
                     (unsigned long long)out->dhash);
    if (n < 0 || (size_t)n >= cap) { free(doc); return B1_ERR_NOMEM; }
    size_t len = (size_t)n;

    for (uint32_t k = 0; k < 16 * 8; k++) {
        int m = snprintf(doc + len, cap - len, "%s%u", k ? "," : "", out->grid[k]);
        if (m < 0 || (size_t)m >= cap - len) { free(doc); return B1_ERR_NOMEM; }
        len += (size_t)m;
    }
    int m = snprintf(doc + len, cap - len, "],\"h\":%u,\"w\":%u}", height, width);
    if (m < 0 || (size_t)m >= cap - len) { free(doc); return B1_ERR_NOMEM; }
    len += (size_t)m;

    b1_status st = b1_digest(doc, len, out->digest_hex);
    free(doc);
    return st;
}

uint32_t b1_signature_distance(const b1_signature *a, const b1_signature *b)
{
    if (!a || !b) return 1000;

    /* Structural term: Hamming distance over the 64-bit difference hash. */
    uint64_t diff = a->dhash ^ b->dhash;
    uint32_t hamming = 0;
    while (diff) { hamming += (uint32_t)(diff & 1u); diff >>= 1; }
    uint32_t structural_mu = hamming * 1000u / 64u;

    /*
     * Tonal term: 1-D Earth Mover's Distance between the per-block histograms, computed as the L1
     * distance between their cumulative distributions.
     *
     * Bin-wise L1 was tried first and is wrong for this purpose: luma buckets have hard edges, so a
     * uniform exposure shift of one bucket moves *all* the mass and scores as the maximum possible
     * difference — a legitimately continuous shot that merely got brighter would read as a total
     * tonal break. EMD instead scores by how far the mass moved, so a one-bucket shift costs about
     * one bucket's worth. This was found by the test asserting that structural change should
     * outweigh exposure change, which bin-wise L1 could not satisfy.
     *
     * Worst case per block is 7e6 (all mass from the lowest bucket to the highest), so the divisor
     * bounds the term to 0..1000 with no floating-point step.
     */
    uint64_t emd = 0;
    for (uint32_t block = 0; block < 16; block++) {
        const uint32_t *ga = a->grid + block * 8;
        const uint32_t *gb = b->grid + block * 8;
        int64_t carry = 0;
        for (uint32_t k = 0; k < 7; k++) { /* the 8th difference is always zero */
            carry += (int64_t)ga[k] - (int64_t)gb[k];
            emd += (uint64_t)(carry < 0 ? -carry : carry);
        }
    }
    uint32_t tonal_mu = (uint32_t)(emd * 1000u / (7000000u * 16u));
    if (tonal_mu > 1000u) tonal_mu = 1000u;

    /*
     * Weighted toward structure: a scene can legitimately change exposure between segments while
     * remaining continuous, but structural change means the frame is genuinely different.
     */
    uint32_t combined = (structural_mu * 700u + tonal_mu * 300u) / 1000u;
    return combined > 1000u ? 1000u : combined;
}
