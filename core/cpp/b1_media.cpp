// B1 media/temporal analyzer.
// Normative: SPEC/50-quality-vector.md §6, SPEC/60-continuity.md §2.
//
// Reads a raw frame sequence (Y4M or a concatenated P6 PPM stream) and computes signal-level
// metrics over it. Raw formats are the ingestion boundary on purpose: the whole verification graph
// must run offline, and depending on a media framework would make the analyzer the one component
// that cannot be built or tested without a network.
//
// Everything here is a PROXY. Inter-frame structural stability is not semantic identity: these
// numbers can say two frames are structurally similar and cannot say the subject is the same
// person. Every metric is emitted with a measurement_basis saying so, because a proxy that loses
// its label on the way into a score becomes a claim nobody checked.

#include "../c/b1_abi.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct Frame {
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> rgb; // width*height*3
};

// --- readers ------------------------------------------------------------------

bool readY4M(std::istream &in, std::vector<Frame> &frames, std::string &err)
{
    std::string header;
    if (!std::getline(in, header)) {
        err = "empty stream";
        return false;
    }
    if (header.rfind("YUV4MPEG2", 0) != 0) {
        err = "not a Y4M stream";
        return false;
    }

    uint32_t w = 0, h = 0;
    std::istringstream hs(header);
    std::string tag;
    while (hs >> tag) {
        if (tag[0] == 'W') w = static_cast<uint32_t>(std::stoul(tag.substr(1)));
        else if (tag[0] == 'H') h = static_cast<uint32_t>(std::stoul(tag.substr(1)));
    }
    if (w == 0 || h == 0) {
        err = "Y4M header did not give both dimensions";
        return false;
    }

    // 4:2:0 planar. Chroma is read and discarded: every metric here is luma-derived, and the
    // frame signature takes RGB, so Y is replicated across the three channels.
    const size_t ySize = static_cast<size_t>(w) * h;
    const size_t cSize = ySize / 4;

    for (;;) {
        std::string marker;
        if (!std::getline(in, marker)) break;
        if (marker.rfind("FRAME", 0) != 0) break;

        Frame f;
        f.width = w;
        f.height = h;
        std::vector<uint8_t> y(ySize);
        if (!in.read(reinterpret_cast<char *>(y.data()), static_cast<std::streamsize>(ySize))) break;
        in.ignore(static_cast<std::streamsize>(cSize * 2));

        f.rgb.resize(ySize * 3);
        for (size_t i = 0; i < ySize; i++) {
            f.rgb[i * 3] = f.rgb[i * 3 + 1] = f.rgb[i * 3 + 2] = y[i];
        }
        frames.push_back(std::move(f));
    }

    if (frames.empty()) {
        err = "Y4M stream contained no frames";
        return false;
    }
    return true;
}

bool readPPMStream(std::istream &in, std::vector<Frame> &frames, std::string &err)
{
    for (;;) {
        std::string magic;
        if (!(in >> magic)) break;
        if (magic != "P6") {
            err = "expected P6 magic, found " + magic;
            return frames.size() > 0;
        }
        uint32_t w = 0, h = 0, maxval = 0;
        if (!(in >> w >> h >> maxval)) break;
        if (maxval != 255) {
            err = "only 8-bit PPM is supported";
            return false;
        }
        in.get(); // the single whitespace byte after the header

        Frame f;
        f.width = w;
        f.height = h;
        f.rgb.resize(static_cast<size_t>(w) * h * 3);
        if (!in.read(reinterpret_cast<char *>(f.rgb.data()),
                     static_cast<std::streamsize>(f.rgb.size()))) {
            break;
        }
        frames.push_back(std::move(f));
    }
    if (frames.empty()) {
        err = "no PPM frames read";
        return false;
    }
    return true;
}

// --- metrics ------------------------------------------------------------------

inline uint32_t luma(const uint8_t *px)
{
    return (299u * px[0] + 587u * px[1] + 114u * px[2]) / 1000u;
}

// Mean absolute luma difference between consecutive frames, in milli-units of full scale.
uint32_t motionEnergy(const Frame &a, const Frame &b)
{
    if (a.width != b.width || a.height != b.height) return 1000;
    const size_t n = static_cast<size_t>(a.width) * a.height;
    uint64_t sum = 0;
    for (size_t i = 0; i < n; i++) {
        uint32_t la = luma(&a.rgb[i * 3]);
        uint32_t lb = luma(&b.rgb[i * 3]);
        sum += (la > lb) ? (la - lb) : (lb - la);
    }
    return static_cast<uint32_t>(sum * 1000u / (n * 255u));
}

// The share of pixels changing by more than a threshold. Distinguishes a whole-frame shift (a
// camera move) from a localized change (a subject moving) — a distinction the mean alone loses.
uint32_t changedShare(const Frame &a, const Frame &b, uint32_t threshold)
{
    if (a.width != b.width || a.height != b.height) return 1000000;
    const size_t n = static_cast<size_t>(a.width) * a.height;
    uint64_t changed = 0;
    for (size_t i = 0; i < n; i++) {
        uint32_t la = luma(&a.rgb[i * 3]);
        uint32_t lb = luma(&b.rgb[i * 3]);
        uint32_t d = (la > lb) ? (la - lb) : (lb - la);
        if (d > threshold) changed++;
    }
    return static_cast<uint32_t>(changed * 1000000u / n);
}

std::string jsonEscape(const std::string &s)
{
    std::string out;
    for (char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        default: out += c;
        }
    }
    return out;
}

} // namespace

int main(int argc, char **argv)
{
    std::string path;
    std::string format = "auto";
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--format" && i + 1 < argc) format = argv[++i];
        else path = arg;
    }

    if (path.empty()) {
        std::cerr << "usage: b1media [--format y4m|ppm] <frames-file>\n"
                  << "  reads a raw frame sequence and emits signal-level metrics as JSON\n";
        return 2;
    }

    std::ifstream file(path, std::ios::binary);
    if (!file) {
        std::cerr << "cannot open " << path << "\n";
        return 3;
    }

    std::vector<Frame> frames;
    std::string err;
    bool ok = false;
    if (format == "y4m") {
        ok = readY4M(file, frames, err);
    } else if (format == "ppm") {
        ok = readPPMStream(file, frames, err);
    } else {
        char probe = static_cast<char>(file.peek());
        if (probe == 'Y') ok = readY4M(file, frames, err);
        else ok = readPPMStream(file, frames, err);
    }

    if (!ok) {
        std::cerr << "read failed: " << err << "\n";
        return 3;
    }

    // Per-frame signatures come from libb1sig over the C ABI (IF-2). The signature is defined once,
    // in C, and is not reimplemented here: duplicating it would create two definitions of the value
    // the continuity chain depends on.
    std::vector<b1_signature> sigs(frames.size());
    for (size_t i = 0; i < frames.size(); i++) {
        b1_status st = b1_frame_signature(frames[i].rgb.data(), frames[i].width, frames[i].height,
                                          &sigs[i]);
        if (st != B1_OK) {
            std::cerr << "signature failed on frame " << i << ": " << b1_status_token(st) << "\n";
            return 3;
        }
    }

    uint64_t energySum = 0, changedSum = 0, sigDistSum = 0;
    uint32_t energyMax = 0, sigDistMax = 0;
    size_t worstIndex = 0;
    for (size_t i = 1; i < frames.size(); i++) {
        uint32_t e = motionEnergy(frames[i - 1], frames[i]);
        uint32_t c = changedShare(frames[i - 1], frames[i], 8);
        uint32_t d = b1_signature_distance(&sigs[i - 1], &sigs[i]);
        energySum += e;
        changedSum += c;
        sigDistSum += d;
        if (e > energyMax) energyMax = e;
        if (d > sigDistMax) { sigDistMax = d; worstIndex = i; }
    }

    const size_t pairs = frames.size() > 1 ? frames.size() - 1 : 1;
    const uint32_t energyMean = static_cast<uint32_t>(energySum / pairs);
    const uint32_t changedMean = static_cast<uint32_t>(changedSum / pairs);
    const uint32_t sigDistMean = static_cast<uint32_t>(sigDistSum / pairs);

    // Temporal stability is the inverse of mean structural drift. A sequence whose consecutive
    // frames are structurally close scores high; one that jumps scores low.
    const uint32_t stability = sigDistMean >= 1000 ? 0 : 1000 - sigDistMean;

    // A single frame pair far above the sequence's own mean is a discontinuity candidate: the
    // signal a cut, a teleport or a dropped frame produces. It is reported as a locus to inspect,
    // never as a conclusion about what happened there.
    const bool spike = frames.size() > 2 && sigDistMax > sigDistMean * 3 && sigDistMax > 100;

    std::string basisNote =
        "PROXY: signal-level structural and tonal comparison. Says whether frames are structurally "
        "similar; cannot establish that a subject is the same person.";

    std::cout << "{"
              << "\"analyzer_version\":\"b1-media/1\","
              << "\"frame_count\":" << frames.size() << ","
              << "\"width_px\":" << frames[0].width << ","
              << "\"height_px\":" << frames[0].height << ","
              << "\"motion_energy_mean_mu\":" << energyMean << ","
              << "\"motion_energy_max_mu\":" << energyMax << ","
              << "\"changed_share_mean_ppm\":" << changedMean << ","
              << "\"signature_distance_mean_mu\":" << sigDistMean << ","
              << "\"signature_distance_max_mu\":" << sigDistMax << ","
              << "\"temporal_stability_mu\":" << stability << ","
              << "\"discontinuity_candidate\":" << (spike ? "true" : "false") << ","
              << "\"discontinuity_frame_index\":" << (spike ? static_cast<long>(worstIndex) : -1) << ","
              << "\"first_frame_signature\":\"" << sigs.front().digest_hex << "\","
              << "\"final_frame_signature\":\"" << sigs.back().digest_hex << "\","
              << "\"measurement_basis\":\"" << jsonEscape(basisNote) << "\""
              << "}\n";

    return 0;
}
