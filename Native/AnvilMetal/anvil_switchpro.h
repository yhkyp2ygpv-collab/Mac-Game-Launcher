// A Nintendo Switch Pro Controller, as a game talking to one over USB sees it.
//
// Games with their own Switch Pro support do not read the pad through XInput. LEGO Star
// Wars: The Skywalker Saga opens any HID device whose path names 057e:2009, performs
// the USB handshake (0x80 0x01 → 0x81 0x01, 0x80 0x02 → 0x81 0x02, 0x80 0x04) and then
// decodes Nintendo's 0x30 input reports byte by byte — read out of the game's own
// SwitchProControllerInputDevicePC. A pad Wine exposes never speaks that protocol, so
// such a game can see a "Pro Controller" and get no input from it at all.
//
// This is the protocol side: pad state in, Nintendo's reports out, and replies to what
// a game writes. No Wine or SDL here, so it can be tested on its own
// (Native/Tools/tests/switchpro_test.cpp).
#pragma once

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace anvil::switchpro {

using Report = std::array<uint8_t, 64>;

/// Buttons by the names printed on a Nintendo pad.
enum Button : uint32_t {
    A = 1u << 0, B = 1u << 1, X = 1u << 2, Y = 1u << 3,
    L = 1u << 4, R = 1u << 5, ZL = 1u << 6, ZR = 1u << 7,
    Minus = 1u << 8, Plus = 1u << 9, LStick = 1u << 10, RStick = 1u << 11,
    Home = 1u << 12, Capture = 1u << 13,
    Up = 1u << 14, Down = 1u << 15, Left = 1u << 16, Right = 1u << 17,
};

struct PadState {
    uint32_t buttons = 0;
    /// -1…1, with right and up positive, as the Switch reports its sticks.
    float lx = 0, ly = 0, rx = 0, ry = 0;
    bool operator==(const PadState& o) const {
        return buttons == o.buttons && lx == o.lx && ly == o.ly && rx == o.rx && ry == o.ry;
    }
    bool operator!=(const PadState& o) const { return !(*this == o); }
};

// Stick centres and reach, in the controller's 12-bit units. LEGO does not read the
// calibration; it takes the top 8 bits of each axis and subtracts fixed centres — 0x81,
// 0x71, 0x81 and 0x79 — clamping to ±90. These centres land exactly on those, so a
// stick at rest reads zero there, and ±1440 is its full ±90. The calibration a game
// can read back from the controller's flash (below) describes the same numbers, so a
// game that does use it (SDL's driver does) reads the same stick.
constexpr int kCenter[4] = {0x818, 0x718, 0x818, 0x798};   // LX, LY, RX, RY
constexpr int kReach = 1440;

inline float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

inline int stickRaw(float value, int center) {
    int raw = center + static_cast<int>(std::lround(clampf(value, -1.f, 1.f) * kReach));
    return raw < 0 ? 0 : (raw > 4095 ? 4095 : raw);
}

/// Two 12-bit values in three bytes, the way every Switch stick field is packed.
inline void pack12(int a, int b, uint8_t* out) {
    out[0] = static_cast<uint8_t>(a & 0xFF);
    out[1] = static_cast<uint8_t>(((a >> 8) & 0x0F) | ((b & 0x0F) << 4));
    out[2] = static_cast<uint8_t>((b >> 4) & 0xFF);
}

/// Bytes 3–5 of an input report: the right-hand buttons, the shared ones, the left.
inline void encodeButtons(uint32_t b, uint8_t* out) {
    uint8_t right = 0, shared = 0, left = 0;
    if (b & Y) right |= 0x01;      if (b & X) right |= 0x02;
    if (b & B) right |= 0x04;      if (b & A) right |= 0x08;
    if (b & R) right |= 0x40;      if (b & ZR) right |= 0x80;
    if (b & Minus) shared |= 0x01; if (b & Plus) shared |= 0x02;
    if (b & RStick) shared |= 0x04; if (b & LStick) shared |= 0x08;
    if (b & Home) shared |= 0x10;  if (b & Capture) shared |= 0x20;
    if (b & Down) left |= 0x01;    if (b & Up) left |= 0x02;
    if (b & Right) left |= 0x04;   if (b & Left) left |= 0x08;
    if (b & L) left |= 0x40;       if (b & ZL) left |= 0x80;
    out[0] = right; out[1] = shared; out[2] = left;
}

/// The HID report descriptor. Every report is 63 bytes behind its id, as on the real
/// controller: 0x30, 0x21 and 0x81 in; 0x01, 0x10, 0x80 and 0x82 out. The collection
/// is vendor-defined rather than a joystick, so nothing that reads HID usages —
/// DirectInput, XInput, raw input — takes Nintendo's bytes for buttons and axes; only
/// a game that knows the protocol reads them.
inline const uint8_t* descriptor(size_t* size) {
    static const uint8_t d[] = {
        0x06, 0x00, 0xFF,         // Usage Page (Vendor 0xFF00)
        0x09, 0x01,               // Usage (0x01)
        0xA1, 0x01,               // Collection (Application)
        0x15, 0x00,               //   Logical Minimum (0)
        0x26, 0xFF, 0x00,         //   Logical Maximum (255)
        0x75, 0x08,               //   Report Size (8)
        0x95, 0x3F,               //   Report Count (63)
        0x85, 0x30, 0x09, 0x30, 0x81, 0x02,   // Report 0x30: Input
        0x85, 0x21, 0x09, 0x21, 0x81, 0x02,   // Report 0x21: Input (subcommand replies)
        0x85, 0x81, 0x09, 0x81, 0x81, 0x02,   // Report 0x81: Input (USB command replies)
        0x85, 0x01, 0x09, 0x01, 0x91, 0x02,   // Report 0x01: Output (rumble + subcommand)
        0x85, 0x10, 0x09, 0x10, 0x91, 0x02,   // Report 0x10: Output (rumble)
        0x85, 0x80, 0x09, 0x80, 0x91, 0x02,   // Report 0x80: Output (USB commands)
        0x85, 0x82, 0x09, 0x82, 0x91, 0x02,   // Report 0x82: Output
        0xC0,                     // End Collection
    };
    *size = sizeof d;
    return d;
}

/// How hard one side of a rumble command asks the motor to run, 0…1.
///
/// Nintendo's "HD rumble" packs a frequency and amplitude for two bands into four
/// bytes. Games write it two ways: properly (SDL, most engines), and as LEGO does —
/// a fixed band with its own 0–255 strength in the low-band amplitude byte.
inline float rumbleStrength(const uint8_t* b) {
    if (b[0] == 0x00 && b[1] == 0x01 && b[2] == 0x40 && b[3] == 0x40) return 0.f;   // neutral
    if (b[1] == 0x00 && b[2] == 0x00 && b[3] == 0x00) return 0.f;                   // LEGO's "off"
    if (b[1] == 0x20 && b[2] == 0x62) return b[3] / 255.f;                          // LEGO's "on"
    const float high = (b[1] & 0xFE) / 200.f;                  // 0xC8 is full amplitude
    const float low = b[3] > 0x40 ? (b[3] - 0x40) / 50.f : 0.f; // 0x72 is full amplitude
    return clampf(high > low ? high : low, 0.f, 1.f);
}

class Emulator {
public:
    explicit Emulator(uint8_t unit = 1) {
        // Nintendo's own prefix, and a unit number so two pads never share an address.
        const uint8_t mac[6] = {0x98, 0xB6, 0xE9, 0x41, 0x4E, static_cast<uint8_t>(0x10 + unit)};
        memcpy(mac_, mac, sizeof mac_);
    }

    void setState(const PadState& s) { state_ = s; }
    const PadState& state() const { return state_; }

    /// The standard full report, 0x30. The timer advances with every report sent.
    Report inputReport() {
        Report r{};
        r[0] = 0x30;
        common(r);
        ++reportsSent_;
        return r;
    }

    /// Everything a game writes. Replies, if any, are appended in the order the
    /// controller would send them.
    void output(const uint8_t* data, size_t length, std::vector<Report>& replies) {
        if (!data || length < 2) return;
        switch (data[0]) {
        case 0x80: usbCommand(data[1], replies); break;
        case 0x01:
            if (length >= 10) rumble(data + 2);
            if (length >= 11) subcommand(data[10], data + 11, length > 11 ? length - 11 : 0, replies);
            break;
        case 0x10:
            if (length >= 10) rumble(data + 2);
            break;
        default:
            break;
        }
    }

    /// The rumble last asked for, per side, once each time it changes.
    bool takeRumble(float& left, float& right) {
        if (!rumbleChanged_) return false;
        rumbleChanged_ = false;
        left = rumbleLeft_;
        right = rumbleRight_;
        return true;
    }

    uint8_t spiByte(uint32_t address) const {
        // 6-axis factory calibration: accelerometer origin and sensitivity, gyroscope
        // origin and sensitivity, little-endian 16-bit each.
        static const uint8_t imu[0x18] = {
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x40, 0x00, 0x40,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3B, 0x34, 0x3B, 0x34, 0x3B, 0x34,
        };
        // Stick parameters (dead zone and range ratio) as a real Pro Controller's flash
        // holds them, for both sticks.
        static const uint8_t params[0x12] = {
            0x0F, 0x30, 0x61, 0x96, 0x30, 0xF3, 0xD4, 0x14, 0x54,
            0x41, 0x15, 0x54, 0xC7, 0x79, 0x9C, 0x33, 0x36, 0x63,
        };
        if (address >= 0x6020 && address < 0x6038) return imu[address - 0x6020];
        if (address >= 0x603D && address < 0x604F) return stickCalibration()[address - 0x603D];
        switch (address) {
        case 0x6012: return 0x03;                                   // device type: Pro Controller
        case 0x601B: return 0x01;                                   // colours are in flash
        case 0x6050: case 0x6051: case 0x6052: return 0x32;         // body
        case 0x6053: case 0x6054: case 0x6055: return 0xFF;         // buttons
        case 0x6056: case 0x6057: case 0x6058: return 0x32;         // left grip
        case 0x6059: case 0x605A: case 0x605B: return 0x32;         // right grip
        default: break;
        }
        if (address >= 0x6086 && address < 0x6098) return params[address - 0x6086];
        if (address >= 0x6098 && address < 0x60AA) return params[address - 0x6098];
        return 0xFF;   // serial, user calibration and everything else: erased
    }

    // Progress, so a log can say how far a game got with the controller.
    bool gotStatusRequest() const { return gotStatus_; }
    bool handshakeDone() const { return gotForceUsb_; }
    uint64_t reportsSent() const { return reportsSent_; }
    uint64_t subcommandsSeen() const { return subcommands_; }

private:
    PadState state_;
    uint8_t mac_[6];
    uint8_t timer_ = 0;
    uint64_t reportsSent_ = 0, subcommands_ = 0;
    bool gotStatus_ = false, gotForceUsb_ = false;
    float rumbleLeft_ = 0, rumbleRight_ = 0;
    bool rumbleChanged_ = false;

    /// Factory stick calibration at 0x603D: the left stick as maximum above centre,
    /// centre, minimum below; the right as centre, minimum below, maximum above.
    const uint8_t* stickCalibration() const {
        static uint8_t c[0x12];
        static bool built = false;
        if (!built) {
            pack12(kReach, kReach, c + 0);
            pack12(kCenter[0], kCenter[1], c + 3);
            pack12(kReach, kReach, c + 6);
            pack12(kCenter[2], kCenter[3], c + 9);
            pack12(kReach, kReach, c + 12);
            pack12(kReach, kReach, c + 15);
            built = true;
        }
        return c;
    }

    /// Bytes 1–12, shared by every input report: timer, battery and connection, buttons,
    /// both sticks, and the vibrator's status.
    void common(Report& r) {
        r[1] = timer_++;
        r[2] = 0x91;   // battery full and charging, powered over USB, a Pro Controller
        encodeButtons(state_.buttons, &r[3]);
        pack12(stickRaw(state_.lx, kCenter[0]), stickRaw(state_.ly, kCenter[1]), &r[6]);
        pack12(stickRaw(state_.rx, kCenter[2]), stickRaw(state_.ry, kCenter[3]), &r[9]);
        r[12] = 0x70;
    }

    void usbCommand(uint8_t command, std::vector<Report>& replies) {
        Report r{};
        r[0] = 0x81;
        r[1] = command;
        switch (command) {
        case 0x01:     // status: controller type and address, the address byte-reversed
            gotStatus_ = true;
            r[2] = 0x00;
            r[3] = 0x03;
            for (int i = 0; i < 6; ++i) r[4 + i] = mac_[5 - i];
            replies.push_back(r);
            break;
        case 0x02:     // handshake
        case 0x03:     // high speed
            replies.push_back(r);
            break;
        case 0x04:     // USB only from now on; no reply, reports simply continue
            gotForceUsb_ = true;
            break;
        default:       // 0x05 (back to Bluetooth), 0x06 (reset) and the rest: no reply
            break;
        }
    }

    void rumble(const uint8_t* blocks) {
        const float left = rumbleStrength(blocks), right = rumbleStrength(blocks + 4);
        if (left != rumbleLeft_ || right != rumbleRight_) {
            rumbleLeft_ = left;
            rumbleRight_ = right;
            rumbleChanged_ = true;
        }
    }

    void subcommand(uint8_t id, const uint8_t* args, size_t argLength, std::vector<Report>& replies) {
        ++subcommands_;
        Report r{};
        r[0] = 0x21;
        common(r);
        r[14] = id;
        uint8_t* data = &r[15];
        switch (id) {
        case 0x02: {   // device information
            r[13] = 0x82;
            const uint8_t info[] = {0x03, 0x48, 0x03, 0x02};
            memcpy(data, info, sizeof info);
            memcpy(data + 4, mac_, 6);
            data[10] = 0x01;
            data[11] = 0x01;
            break;
        }
        case 0x04:     // how long the triggers have been held: never
            r[13] = 0x83;
            break;
        case 0x10: {   // read flash
            r[13] = 0x90;
            if (argLength >= 5) {
                uint32_t address;
                memcpy(&address, args, 4);
                uint8_t count = args[4];
                if (count > 0x1D) count = 0x1D;
                memcpy(data, args, 5);
                for (uint8_t i = 0; i < count; ++i) data[5 + i] = spiByte(address + i);
            }
            break;
        }
        case 0x21: {   // NFC/IR configuration: acknowledged as a controller without it
            r[13] = 0xA0;
            const uint8_t mcu[] = {0x01, 0x00, 0xFF, 0x00, 0x08, 0x00, 0x1B, 0x01};
            memcpy(data, mcu, sizeof mcu);
            break;
        }
        case 0x31:     // which player lights are on: the first
            r[13] = 0xB0;
            data[0] = 0x01;
            break;
        case 0x50:     // battery voltage
            r[13] = 0xD0;
            data[0] = 0x18;
            data[1] = 0x06;
            break;
        default:       // input mode, player lights, IMU, vibration, and the rest: done
            r[13] = 0x80;
            break;
        }
        replies.push_back(r);
    }
};

} // namespace anvil::switchpro
