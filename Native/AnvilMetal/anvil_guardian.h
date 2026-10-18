// Guardian's learning: whether Smooth Motion's frames between pay for themselves, at each frame rate of
// a game's own, on this Mac — learned from short checks while the game is played, kept between sessions.
//
// A frame made between two of the game's costs the game a little of its own (the made frame's GPU work,
// the presenter's copies, the real frame shown half a frame later), and what that buys differs by Mac and
// by game: an M4 makes LEGO Star Wars' made frame in 1.5 ms, a base M1 in about four times that; a game
// that waits for its frames to reach the screen loses more of its own than one that doesn't. Rules tuned
// on one Mac are wrong on another. So now and then, with frames between running steadily, Guardian shows
// the game's own frames alone for a few seconds and compares — the same scene, seconds apart — and where
// frames between have been found to cost more than they give, it leaves them off there, and looks again
// now and then in case that has changed.
#pragma once
#include <cstddef>

namespace anvil_guardian {

/// One of libanvil's decision windows, about two seconds of play.
struct Window {
    double now = 0.0;        // seconds, on CACurrentMediaTime's clock
    double seconds = 0.0;    // the window's length
    double own = 0.0;        // the game's own frames a second
    double shown = 0.0;      // frames that reached the screen a second, made ones included
    double gapMeanMs = 0.0;  // between frames on the screen
    double gapSdMs = 0.0;
    bool between = false;    // Smooth Motion made frames between through the window
    bool eligible = false;   // it could have: the game in front, FSR 3 on, its rate in Smooth Motion's range
    bool calm = true;        // nothing of Anvil's changed in it — no hold let go, no FSR eased, no switch
};

enum class Action { none, probeOff, probeOn, endProbe, abortProbe };

/// Where the learned state is kept (nil: nowhere — learned for the session only), and whether the checks
/// run at a test's pace (seconds instead of minutes).
void configure(const char* statePath, bool fast);
/// The learned state from its file. False without one: a first session on this Mac.
bool load();
bool save();
void reset();

/// What a window was worth on the screen: the game's frames, made ones counted at 0.7 of a real one (a
/// frame between is right where motion is plain and approximate where it isn't), times how evenly they
/// were shown.
double score(const Window& w);
/// Smooth Motion's range, in bands of the game's own frame rate. -1 outside it.
int bandOf(double own);
int bandCount();
void bandRange(int band, double* lo, double* hi);
/// False where frames between have been found to cost more than they give at this rate.
bool betweenWanted(double own);
/// Each window: what to do now.
Action step(const Window& w);
/// Frames between held the game below what it made before them with the GPU going idle (libanvil's own
/// guard): counted against them at that rate, as a check that found them a third worse.
void noteCost(double own);

/// The check that just ended, for the log.
struct Result {
    int band = -1;
    double lo = 0.0, hi = 0.0;   // the band's rates
    double change = 0.0;         // frames between against the game's own alone, as a fraction (+0.4: 40% better)
    int n = 0;                   // checks in the band so far
    double mean = 0.0;           // their average
    bool wanted = true;          // frames between at this rate from here
};
bool lastResult(Result* r);
/// What has been learned, in words, for the log. Characters written.
int describe(char* out, size_t room);
int checksThisSession();

}  // namespace anvil_guardian
