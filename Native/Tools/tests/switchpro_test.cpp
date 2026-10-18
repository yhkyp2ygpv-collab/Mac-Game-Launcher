// The virtual Switch Pro Controller against the two readers it has to satisfy.
//
// 1. LEGO Star Wars: The Skywalker Saga's SwitchProControllerInputDevicePC, whose USB
//    handshake and 0x30 decoder are reproduced below instruction for instruction from
//    LEGOSTARWARSSKYWALKERSAGA_DX11.exe (0x14344dbd0 and 0x14344dcbe).
// 2. The setup a full driver such as SDL's performs: status, handshake, device info,
//    flash reads for the stick calibration, input mode, lights, IMU and vibration.
//
//   clang++ -std=c++17 -I Native/AnvilMetal Native/Tools/tests/switchpro_test.cpp -o /tmp/switchpro_test && /tmp/switchpro_test
#include "anvil_switchpro.h"

#include <cstdio>
#include <cstdlib>
#include <string>

using namespace anvil::switchpro;

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// --- LEGO's decoder ------------------------------------------------------------------

struct LegoPad { uint32_t mask; float lx, ly, rx, ry; };

static int8_t clamp90(int8_t v) { return v >= 0x5a ? 0x5a : (v < -0x5a ? -0x5a : v); }

static LegoPad legoDecode(const uint8_t* rsi) {
    uint32_t r8 = rsi[2] | rsi[3] << 8 | rsi[4] << 16 | (uint32_t)rsi[5] << 24;   // mov r8d, [rsi+2]
    const uint32_t ebx = r8 >> 0x19, r11 = r8 >> 0x18, r9 = r8 >> 0xc, edx = r8 >> 7;
    uint32_t r10 = (r8 >> 1) & 0x40000000;
    r10 = (r10 | (r8 & 0x1000000)) >> 0xd;
    r10 = (r10 | (r8 & 0x80000)) >> 3;
    r10 = (r10 | (r8 & 0x8000)) >> 3;
    r10 = (r10 | (r8 & 0x100000)) >> 3;
    uint32_t ecx = (r8 & 0x100) << 3;
    ecx |= r8 & 0x400;  ecx += ecx;
    ecx |= r8 & 0x200;  ecx += ecx;
    ecx |= r8 & 0x800;  ecx <<= 2;
    r10 |= ecx | (edx & 0x880) | (r9 & 0x30) | (r11 & 0x48) | (ebx & 3);

    const int8_t dl  = clamp90((int8_t)(uint8_t)(((rsi[6] >> 4) | (rsi[7] << 4)) + 0x7f));
    const int8_t cl  = clamp90((int8_t)(uint8_t)(((rsi[9] >> 4) | (rsi[10] << 4)) + 0x7f));
    const int8_t r8b = clamp90((int8_t)(uint8_t)(rsi[8] - 0x71));
    const int8_t r9b = clamp90((int8_t)(uint8_t)(rsi[11] - 0x79));
    return {r10, dl / 90.f, r8b / 90.f, cl / 90.f, r9b / 90.f};
}

// LEGO's own button bits, by what they are.
enum LegoBit : uint32_t {
    lUp = 1 << 0, lRight = 1 << 1, lDown = 1 << 2, lLeft = 1 << 3, lMinus = 1 << 4, lPlus = 1 << 5,
    lL = 1 << 6, lR = 1 << 7, lZL = 1 << 8, lZR = 1 << 9, lLS = 1 << 10, lRS = 1 << 11,
    lNorth = 1 << 12, lEast = 1 << 13, lSouth = 1 << 14, lWest = 1 << 15, lHome = 1 << 17,
};

// LEGO's reader loop (0x14344dbd0): writes 0x80 0x01, answers 0x81 0x01 with 0x80 0x02
// and 0x81 0x02 with 0x80 0x04, and decodes every 0x30.
static void legoSession(Emulator& emu) {
    std::vector<Report> inbox;
    auto write = [&](uint8_t a, uint8_t b) {
        Report w{}; w[0] = a; w[1] = b;
        emu.output(w.data(), w.size(), inbox);
    };
    write(0x80, 0x01);
    int handshakes = 0;
    for (size_t i = 0; i < inbox.size(); ++i) {
        const Report r = inbox[i];
        if (r[0] == 0x81 && r[1] == 0x01) { write(0x80, 0x02); ++handshakes; }
        else if (r[0] == 0x81 && r[1] == 0x02) { write(0x80, 0x04); ++handshakes; }
    }
    CHECK(handshakes == 2, "LEGO's handshake got %d of its 2 replies", handshakes);
    CHECK(emu.handshakeDone(), "the emulator did not see 0x80 0x04");
    CHECK(inbox.size() == 2, "expected exactly two replies, got %zu", inbox.size());
    CHECK(inbox[0][3] == 0x03, "status reply says controller type %02x, not a Pro Controller", inbox[0][3]);
}

static void testLegoButtons() {
    struct Case { uint32_t button; uint32_t lego; const char* name; };
    // The physical layout is Nintendo's: A right, B bottom, X top, Y left.
    const Case cases[] = {
        {A, lEast, "A (right)"}, {B, lSouth, "B (bottom)"}, {X, lNorth, "X (top)"}, {Y, lWest, "Y (left)"},
        {L, lL, "L"}, {R, lR, "R"}, {ZL, lZL, "ZL"}, {ZR, lZR, "ZR"},
        {Minus, lMinus, "−"}, {Plus, lPlus, "+"}, {LStick, lLS, "left stick"}, {RStick, lRS, "right stick"},
        {Home, lHome, "Home"}, {Up, lUp, "up"}, {Down, lDown, "down"}, {Left, lLeft, "left"}, {Right, lRight, "right"},
    };
    Emulator emu;
    legoSession(emu);
    for (const Case& c : cases) {
        emu.setState(PadState{c.button});
        const Report r = emu.inputReport();
        CHECK(r[0] == 0x30, "report id %02x", r[0]);
        const LegoPad p = legoDecode(r.data());
        CHECK(p.mask == c.lego, "%s reached LEGO as %05x, wanted %05x", c.name, p.mask, c.lego);
    }
    // Capture has no LEGO bit and must not set one.
    emu.setState(PadState{Capture});
    CHECK(legoDecode(emu.inputReport().data()).mask == 0, "Capture set a LEGO button");
    // Everything at once decodes to everything at once.
    uint32_t all = 0, allLego = 0;
    for (const Case& c : cases) { all |= c.button; allLego |= c.lego; }
    emu.setState(PadState{all});
    CHECK(legoDecode(emu.inputReport().data()).mask == allLego, "all buttons together decoded wrong");
}

static void testLegoSticks() {
    Emulator emu;
    struct Case { float lx, ly, rx, ry; };
    const Case cases[] = {
        {0, 0, 0, 0}, {1, 0, 0, 0}, {-1, 0, 0, 0}, {0, 1, 0, 0}, {0, -1, 0, 0},
        {0, 0, 1, 0}, {0, 0, -1, 0}, {0, 0, 0, 1}, {0, 0, 0, -1}, {0.5f, -0.5f, 0.25f, 0.75f},
    };
    for (const Case& c : cases) {
        emu.setState(PadState{0, c.lx, c.ly, c.rx, c.ry});
        const LegoPad p = legoDecode(emu.inputReport().data());
        const float tolerance = 1.f / 90.f + 1e-4f;   // LEGO keeps the top 8 bits: 90 steps
        CHECK(std::fabs(p.lx - c.lx) <= tolerance && std::fabs(p.ly - c.ly) <= tolerance &&
              std::fabs(p.rx - c.rx) <= tolerance && std::fabs(p.ry - c.ry) <= tolerance,
              "sticks (%.2f %.2f %.2f %.2f) reached LEGO as (%.3f %.3f %.3f %.3f)",
              c.lx, c.ly, c.rx, c.ry, p.lx, p.ly, p.rx, p.ry);
        CHECK(p.mask == 0, "a stick set button bits %05x", p.mask);
    }
    // At rest LEGO must read exactly zero, or characters creep.
    emu.setState(PadState{});
    const LegoPad rest = legoDecode(emu.inputReport().data());
    CHECK(rest.lx == 0 && rest.ly == 0 && rest.rx == 0 && rest.ry == 0,
          "at rest LEGO reads (%f %f %f %f)", rest.lx, rest.ly, rest.rx, rest.ry);
}

static void testLegoRumble() {
    // LEGO's 0x10 report (0x14344d4a0): left block 80 20 62 <strength>, right 98 20 62 <strength>.
    Emulator emu;
    std::vector<Report> replies;
    const uint8_t on[] = {0x10, 0x01, 0x80, 0x20, 0x62, 0xFF, 0x98, 0x20, 0x62, 0x80};
    emu.output(on, sizeof on, replies);
    float l = -1, r = -1;
    CHECK(emu.takeRumble(l, r), "rumble change not reported");
    CHECK(std::fabs(l - 1.f) < 1e-3f && std::fabs(r - 128 / 255.f) < 1e-3f, "rumble read as %.3f / %.3f", l, r);
    CHECK(!emu.takeRumble(l, r), "unchanged rumble reported twice");
    const uint8_t off[] = {0x10, 0x02, 0x80, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00};
    emu.output(off, sizeof off, replies);
    CHECK(emu.takeRumble(l, r) && l == 0 && r == 0, "LEGO's off pattern read as %.3f / %.3f", l, r);
    // LEGO's player-light subcommand is answered and changes nothing else.
    const uint8_t lights[] = {0x01, 0x03, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x30, 0x01};
    emu.output(lights, sizeof lights, replies);
    CHECK(!replies.empty() && replies.back()[0] == 0x21 && replies.back()[13] == 0x80 && replies.back()[14] == 0x30,
          "player lights not acknowledged");
    CHECK(emu.takeRumble(l, r) == false, "neutral rumble in the light command counted as a change");
    CHECK(replies.size() == 1, "rumble-only reports must not be answered (%zu replies)", replies.size());
}

// --- A full driver's setup -----------------------------------------------------------

static Report subcommand(Emulator& emu, uint8_t id, std::vector<uint8_t> args = {}) {
    std::vector<Report> replies;
    Report w{};
    w[0] = 0x01; w[1] = 0x05;
    const uint8_t neutral[8] = {0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40};
    memcpy(&w[2], neutral, 8);
    w[10] = id;
    memcpy(&w[11], args.data(), args.size());
    emu.output(w.data(), w.size(), replies);
    CHECK(replies.size() == 1, "subcommand %02x answered %zu times", id, replies.size());
    CHECK(replies.empty() || (replies[0][0] == 0x21 && replies[0][14] == id), "subcommand %02x reply malformed", id);
    return replies.empty() ? Report{} : replies[0];
}

static int unpackLow(const uint8_t* p) { return p[0] | ((p[1] & 0x0F) << 8); }
static int unpackHigh(const uint8_t* p) { return (p[1] >> 4) | (p[2] << 4); }

static void testDriverSetup() {
    Emulator emu(2);
    std::vector<Report> replies;
    for (uint8_t c : {0x01, 0x02, 0x03, 0x02, 0x04}) {
        Report w{}; w[0] = 0x80; w[1] = c;
        emu.output(w.data(), w.size(), replies);
    }
    CHECK(replies.size() == 4, "USB commands answered %zu times, wanted 4", replies.size());

    Report info = subcommand(emu, 0x02);
    CHECK(info[13] == 0x82 && info[15 + 2] == 0x03, "device info: ack %02x type %02x", info[13], info[15 + 2]);
    CHECK(info[15 + 4] == 0x98 && info[15 + 5] == 0xB6 && info[15 + 6] == 0xE9, "device info address is not Nintendo's");

    // Factory stick calibration, left then right, the way SDL decodes it.
    Report cal = subcommand(emu, 0x10, {0x3D, 0x60, 0x00, 0x00, 0x12});
    CHECK(cal[13] == 0x90 && cal[15] == 0x3D && cal[16] == 0x60 && cal[19] == 0x12, "flash read echo wrong");
    const uint8_t* d = &cal[20];
    const int lMaxX = unpackLow(d), lMaxY = unpackHigh(d), lCenX = unpackLow(d + 3), lCenY = unpackHigh(d + 3);
    const int lMinX = unpackLow(d + 6), lMinY = unpackHigh(d + 6);
    const int rCenX = unpackLow(d + 9), rCenY = unpackHigh(d + 9), rMinX = unpackLow(d + 12), rMaxX = unpackLow(d + 15);
    CHECK(lCenX == kCenter[0] && lCenY == kCenter[1] && rCenX == kCenter[2] && rCenY == kCenter[3],
          "calibration centres %03x %03x %03x %03x", lCenX, lCenY, rCenX, rCenY);
    CHECK(lMaxX == kReach && lMaxY == kReach && lMinX == kReach && lMinY == kReach && rMinX == kReach && rMaxX == kReach,
          "calibration reach wrong");

    // Read through the calibration, the stick report means what it says.
    emu.setState(PadState{0, 1.f, -1.f, 0, 0});
    const Report in = emu.inputReport();
    const int lx = unpackLow(&in[6]), ly = unpackHigh(&in[6]);
    CHECK(lx - lCenX == kReach && lCenY - ly == kReach, "left stick raw %03x %03x", lx, ly);

    for (uint8_t id : {0x03, 0x30, 0x38, 0x40, 0x48, 0x08}) {
        Report ack = subcommand(emu, id, {0x01});
        CHECK(ack[13] == 0x80, "subcommand %02x ack %02x", id, ack[13]);
    }
    Report user = subcommand(emu, 0x10, {0x10, 0x80, 0x00, 0x00, 0x16});
    CHECK(user[20] == 0xFF && user[21] == 0xFF, "user calibration should read as absent");
    CHECK(emu.subcommandsSeen() == 9, "counted %llu subcommands", (unsigned long long)emu.subcommandsSeen());
}

static void testDescriptor() {
    // Walk the descriptor the way a HID parser does and add up each report's length.
    size_t size = 0;
    const uint8_t* d = descriptor(&size);
    int reportSize = 0, reportCount = 0, id = 0;
    int inputBits[256] = {}, outputBits[256] = {};
    for (size_t i = 0; i < size;) {
        const uint8_t prefix = d[i];
        const int len = (prefix & 3) == 3 ? 4 : (prefix & 3);
        uint32_t value = 0;
        for (int k = 0; k < len; ++k) value |= d[i + 1 + k] << (8 * k);
        switch (prefix & 0xFC) {
        case 0x74: reportSize = value; break;
        case 0x94: reportCount = value; break;
        case 0x84: id = value; break;
        case 0x80: inputBits[id] += reportSize * reportCount; break;
        case 0x90: outputBits[id] += reportSize * reportCount; break;
        default: break;
        }
        i += 1 + len;
    }
    for (int in : {0x30, 0x21, 0x81}) CHECK(inputBits[in] == 63 * 8, "input report %02x is %d bits", in, inputBits[in]);
    for (int out : {0x01, 0x10, 0x80, 0x82}) CHECK(outputBits[out] == 63 * 8, "output report %02x is %d bits", out, outputBits[out]);
}

int main() {
    testLegoButtons();
    testLegoSticks();
    testLegoRumble();
    testDriverSetup();
    testDescriptor();
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("switchpro: all checks passed\n");
    return 0;
}
