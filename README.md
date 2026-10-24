# Anvil — Mac Game Launcher

**Play your Windows games from Steam and Epic Games on a Mac, and have them run smoother.**

If you ever wanted to play games on your Mac but couldn't because they weren't made for Mac,
Anvil fixes that. It installs and runs Windows games on Apple silicon Macs, then tunes each
one while you play: sharper upscaling, extra frames in heavy scenes, even frame pacing,
working controllers and surround sound.

### [⬇ Download Anvil 0.66.0](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/latest)

Free · Apple silicon (M1 or later) · macOS 14 Sonoma or newer · **Open source**

> **Anvil is open source** — its full source code is in this repository, under the
> [Anvil Source License](LICENSE.txt). Use it, build it, improve it and share it for free.
>
> **If you clone or fork Anvil, please add me as a collaborator and put me in your credits:**
> *Jay Chirag Patel ([@yhkyp2ygpv-collab](https://github.com/yhkyp2ygpv-collab))* — in your
> README and credits, and as a collaborator on your repository.
>
> **Selling it or publishing it for money? Talk to me first** — open an issue titled
> "Commercial use". It needs my written permission.

---

## Features

- **Steam and Epic Games** — sign in, see your library, install and play.
- **AMD FSR upscaling in every game** — FSR 1 or FSR 3 to your display's full resolution,
  with textures sharpened to match. DLSS games can use Apple's MetalFX instead.
- **Smooth Motion** — in heavy scenes, a frame made between each two of the game's own:
  40 fps is shown as 80. Each made frame is checked first; where the two real frames disagree
  (reflections, heat, fast chaos), the real frame is shown instead of a warped one. Works on
  ProMotion and on regular 60 Hz displays.
- **Look Check** — shows what's on and off in a game's picture (reflections, shadows, blur,
  ray tracing) and why, with one click to turn reflections or the game's own look back on.
- **Guardian** — a small self-learning helper inside each game. Every few seconds it checks
  that everything is working, fixes what it can on the spot, and learns what runs best on
  *your* Mac.
- **Steady frame pacing** — even frame times on ProMotion and regular displays, so 40 fps
  feels like 40 and not like stutter.
- **Auto-Tune** — measures each game on your Mac and picks its settings and engine for you.
- **Anvil Learn** — learns from every session how each game runs on *your* Mac and what
  each of its settings costs there, then tunes it after you play and while you're away.
- **Microsoft's Visual C++ Runtime, put in for you** — for games whose launchers look for it
  (Unreal Engine games such as Hogwarts Legacy), installed once from Microsoft's own signed
  installer.
- **Graphics Prep** — Anvil's upscaling and frame generation are compiled and tested on your
  Mac before the game starts, and the game's shader cache is kept between sessions.
- **Controllers** — Xbox, PlayStation and Switch Pro controllers, with a built-in tester.
- **Minecraft** — Java Edition through Mojang's own launcher, and Bedrock's PC version in
  Windows through VMware Fusion, set up by Anvil and started straight into the game.
- **3D surround sound** — spatial audio for every game, and stereo turned into surround.
- **Memory warm-up** — the parts of a game you play most are read into your Mac's spare
  unified memory as it starts, so places you've been load from memory, not the disk.
- **Save Guard** — automatic backups of your saves, and every export kept twice. A game you
  download again gets its saves back: you choose which, and Anvil shows how far through each
  one is (LEGO games) and picks the one with the most progress. Any restore can be undone.
- **Doctor and Check-Up** — after each session, Anvil explains in plain words what slowed
  the game down or went wrong, and what it changed.

## Why Anvil?

[Mythic](https://github.com/MythicApp/Mythic) and
[Heroic](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher) are great free,
open-source launchers. Anvil runs games on the same kind of engine (Wine with Apple's
D3DMetal), so which games start is about the same. What Anvil adds is what happens
**while the game runs**:

| | **Anvil** | Mythic | Heroic |
|---|:---:|:---:|:---:|
| Steam games | ✅ | ✅ | — |
| Epic Games | ✅ | ✅ | ✅ |
| GOG and Amazon | — | — | ✅ |
| AMD FSR upscaling in every game | ✅ | — | — |
| Frame generation (Smooth Motion), checked frame by frame | ✅ | — | — |
| Frame pacing for ProMotion displays | ✅ | — | — |
| Automatic per-game tuning | ✅ | — | — |
| In-game controller fixes (Switch Pro, input lag) | ✅ | — | — |
| 3D surround sound | ✅ | — | — |
| Save backups | ✅ on your Mac | — | ✅ cloud sync |
| Plain-English problem reports | ✅ | — | — |
| Self-learning in-game checks (Guardian) | ✅ | — | — |
| Memory warm-up for game data | ✅ | — | — |
| Ray tracing turned on for DirectX 12 games that have it (M3/M4) | ✅ | — | — |
| Runs on | Apple silicon Macs | Macs | Mac, Windows, Linux |

<sub>— means not listed in that project's README (October 2026). Heroic also supports more
stores and Intel Macs (through CrossOver). If something here is out of date, tell me in the
feedback form below.</sub>

## Install

1. Download `Anvil-0.66.0.dmg` from
   [Releases](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/latest).
2. Open it and drag **Anvil** into **Applications**.
3. Open Anvil. If macOS says it "cannot verify" Anvil, go to
   **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. You only
   do this once.
4. Follow the setup. It downloads the game engine (about 200 MB) and offers to set up
   Steam and sign in to Epic Games.

**You need:** an Apple silicon Mac (M1 or later), macOS 14 or newer, Rosetta (setup tells
you how to add it), and about 2 GB free plus room for your games.

Your passwords go only to Steam's and Epic's own sign-in pages, never to Anvil. Anvil has no
analytics or tracking, and what Guardian learns stays on your Mac.

## Feedback

**[Send feedback →](https://forms.gle/yeVUm6zrFtYNeHgT7)**

**It's anonymous.** No Google sign-in, and no name or email is asked for or collected. Only
your answers are seen.

The form asks three things: what kind of problem it was (performance, graphics, Steam or
Epic sign-in, or something else), which game, and what happened. It helps to add your Mac
(for example "M2 MacBook Air, 16 GB") and what you were doing in the game.

Please leave out personal details such as account names or email addresses.

## Use at your own discretion

- **Online and multiplayer games.** Playing online through Anvil is your choice and at your
  own risk. Most game makers don't officially support playing on a Mac through Wine. Their
  anti-cheat and their rules decide what's allowed, including account bans.
  - Anvil never tries to get around anti-cheat, DRM, or store sign-in and ownership checks.
  - When Anvil finds anti-cheat in a game, it puts none of its own files in that game's
    folder.
  - Games with kernel anti-cheat (Riot Vanguard, EA Javelin and others) can't run online on
    a Mac. Anvil marks these games.
  - Easy Anti-Cheat and BattlEye games work online only where the game's maker allows Wine.
  - If you're worried about an account, stick to single-player, or check the game's rules
    first.
- **Store accounts.** Your Steam and Epic accounts are yours, and their terms apply.
- **Saves.** Anvil backs up saves, but keep your own copy of anything you can't lose. Use
  the game's cloud saves where it has them.
- **Early software.** Anvil is at version 0.x and changes quickly. Some games won't start
  or will run slowly, and results differ from Mac to Mac.
- **Not notarized by Apple.** That's why macOS asks you to confirm the first time. Each
  release lists the DMG's SHA-256, so you can check your download.
- **No warranty.** Anvil is provided "as is"; see [LICENSE.txt](LICENSE.txt).

## What's new in 0.66.0

- **Full frame rate the moment a MacBook's lid opens on a game.** Anvil's hidden window had been taking the front after
  wake, which held the game at 10 fps until you switched away and back. It now hands the front straight back to the game.
- **The pointer hides while you play** with the mouse left alone, and comes back the moment it moves.
- **No stutter when the front is lost for a moment:** the background hold starts only after two seconds.
- **Ray tracing blocked by Anvil's Ray Tracing switch** is now explained in the log and on the game's page, so it can be
  turned on where it's chosen.

## In 0.65.0

- **Ray tracing from a game's own settings.** For Hogwarts Legacy, choose Reflections, all three effects, or Off on its
  page. It's traced by the GPU's ray-tracing hardware (M3 and later). With DLSS as the upscaler, Ray Reconstruction
  cleans it up, and D3DMetal runs that as Apple's MetalFX denoiser. Automatic leaves it as set in the game's menu.
- **No more background drain.** A game behind other apps drops to 10 fps after two minutes, and to 5 fps with the
  screen locked or asleep. Before, it stayed at 30 fps for hours.
- **Fixed:** the memory check now reads the game's last three sessions, not one. Loading pauses are reported apart
  from freezes. Learn no longer misreads ray-tracing settings from sessions that didn't trace rays.

## In 0.64.0

- **Graphics for an even 80.** After each session that held 80 fps less than 80% of the time, Anvil lowers the setting
  that costs the most for the least to see — Effects, then fog, shadows, foliage, post-processing — a step at a time,
  never below High and never textures, and puts them back up when there's room. Or keep exactly what you set.
- **Fixed:** the game's own made frames were counted as its own, which raised quality when it should have stayed.

## In 0.63.0

- **Real frame generation.** Where a game has its own — AMD FSR 3's in Hogwarts Legacy, made from the game's own
  motion vectors and depth — Anvil turns it on and steps its own Smooth Motion aside, taking the picture to the
  display with FSR 1 alone. Hogwarts Legacy at Ultra on a base M4 averaged 67 fps this way, against 29–48 with Anvil's
  own frame generation, which took 5–8 ms of every frame.
- **Sharper over a game's own upscaler** (70% sharpening, the game's own back at its default).
- **A memory check before a big game starts**, naming the apps using the most when the game won't fit in what's free.

## In 0.62.0

- **A game's own AI upscalers, chosen in Anvil.** For Hogwarts Legacy, pick **DLSS** or **Intel XeSS** on its
  Performance tab. DLSS's own network needs NVIDIA hardware, so Apple's D3DMetal runs it as **MetalFX**, Apple's
  temporal upscaler. XeSS is Intel's AI upscaler and runs on any GPU. **Automatic** picks DLSS, then XeSS, and
  writes the choice into the game's own settings before it starts.
- **Quality that fits your Mac.** Automatic starts at Balanced on a base M4. After each session it moves a step
  sharper if the game had room to spare, or a step faster if the GPU held it back.
- **No more grainy edges from doing things twice.** Anvil no longer:
  - sharpens on top of the game's own sharpening,
  - sharpens textures on top of the game's own upscaler,
  - runs its frame generation alongside the game's.

  Film grain and colour fringing are off by default ("Clean picture").
- **Fixed:**
  - Freezes of 1–2.6 seconds with Smooth Motion on. Its presenter now gets full priority when it falls behind, and
    the game gets its own frames back within 0.4 s if it ever stalls.
  - A bug that let Smooth Motion restart seconds after a freeze.
  - Hitches from memory: the warm-up leaves room for what a big game takes (Hogwarts at Ultra uses up to 21 GB).
  - Smooth Motion switching on and off every few seconds in a game held to 60 fps.
  - A crash in Hogwarts Legacy blamed on FSR. It was the game asking Windows for its on-screen keyboard, which Wine
    doesn't have.
  - Hogwarts Legacy's saves (under "Phoenix") are now found and exported.
  - Restoring one game's saves no longer puts back another game's.

## In 0.61.0

- **Download the DLC you own.** Each Epic game's page lists your DLC first — Installed, or a
  **Download** button with its progress — and folds away the DLC you don't own. A **Download
  Your DLC** button appears at the top of the page (and beside the game on the Epic page)
  whenever some of yours isn't downloaded yet.
- **Installing an Epic game brings its DLC** — before, only the game came down.
- **Steam games list the DLC you own**, with **Show in Steam**; Steam downloads it with the game.

## In 0.60.0

- **See what's in each save before you choose.** For LEGO games Anvil reads the game's own slot
  line from each copy — "Episode Select · 34.3% complete", "Coruscant · Episode I · 2.5%" — and
  shows it with a progress bar. It picks the one with the **most progress**, not just the newest:
  the newest copy can be a new game started over the old one.
- **Your whole history to choose from.** The backups Anvil makes before each play are listed
  too, folded away under their own heading, one per point in the game. Copies holding the same
  saves are listed once.
- **Undo.** Right after a restore, or with **Undo Last Restore** on the game's page, Anvil puts
  back what the game had just before. **Restore from a File…** now keeps that copy first too.
- **Fixes:** choosing saves no longer asks again a moment later (which put a new game back over
  the restored one); a Documents folder shared by every Windows setup (Cat Quest II's) is no
  longer offered as "left in another setup"; exports whose files have no spaces in their paths
  are counted properly; and Anvil says so in its window when macOS's Documents permission
  question is what it's waiting on.

## In 0.59.1

- **Your saves come back when a game does.** Delete a game and its saves are exported, and
  each export is now kept twice: in Documents › Anvil Saves and inside Anvil. When you download
  the game again, Anvil lists every export and any old saves it finds, newest first, with when
  each was exported and when the game last saved. It puts back the ones you pick, and exports
  what the game had first, so nothing is lost either way. **Choose Saves from Before** on a
  game's page does it any time.

## In 0.59.0

- **Anvil Learn.** Anvil learns how each game runs on your Mac from every session. Every
  few seconds of play is kept with how heavy the scene was, so it can tell what a setting
  costs from where you happened to be playing. It then predicts what each setup would do over
  the play it has seen. On LEGO Star Wars it was 10.5 points off the real share of time at
  80 fps, against 16.8 for the old way. It measured the game's reflections at about 1.2 ms a
  frame on a base M4.
- **Tuned after every session**, on Automatic. The **Ray Tracing switch on Automatic** keeps
  reflections on wherever they cost almost nothing in smoothness.
- **Unreal Engine games:** Anvil learns what each of the game's own quality settings costs
  from your changes in its menu, and tells you which one to lower first.
- **While you're away**, Anvil learns from missed sessions and re-prepares graphics after an
  update, so your next start doesn't wait.
- **Back after a break:** after the Mac sleeps or a game sits paused, Smooth Motion, FSR 3
  and frame pacing start fresh instead of waiting out a pause from before.
- **Hogwarts Legacy and other Unreal games** are read as the game, not their launcher:
  DirectX 12 with ray tracing on Macs that trace rays in hardware.
- **No more "Known issues with graphics driver" warning** in Unreal games. The "AMD driver"
  Unreal checks is really D3DMetal, so the warning is always wrong on a Mac.
- **A small frame counter again.** Asking for the Mac's heat no longer brings up Apple's
  full-screen Metal panel. Anvil's counter turns red when the Mac is hot.

## In 0.58.2

- **Games that need Microsoft's Visual C++ Runtime get it.** Hogwarts Legacy stopped at
  "The following component(s) are required to run this program: Microsoft Visual C++
  Runtime": Unreal Engine's launcher looks for the registry key Microsoft's installer writes,
  which Wine's own files don't. Anvil now finds every game that needs the runtime and runs
  **Microsoft's own installer** in that game's Windows setup, once and quietly, after
  checking that it is signed by Microsoft.
- **No more "Registry Editor" message** before Five Nights at Freddy's: Into the Pit (and
  other Unity games on the newer engine). Anvil wrote one of its own settings wrongly, and
  Wine 9 said so in a window.
- **Nothing graphical is switched off for a game that closed before drawing anything.**

## In 0.58.1

- **Anvil is open source.** Its full source code is in this repository under the
  [Anvil Source License](LICENSE.txt) — see [Build from source](#build-from-source). Settings ›
  About in the app links here and states the licence. Nothing about how Anvil plays has
  changed since 0.58.0.

## In 0.58.0

- **Smooth Motion through explosions, lightning and fire.** In effects-heavy scenes Smooth
  Motion used to give up on whole frames and show a real frame twice (64% of made frames in
  one evening of LEGO Star Wars). Now it shows the real frame only *where* the two frames
  disagree (the flames, sparks or a reflection) and keeps camera and character motion smooth
  everywhere else.
- **Crashes blamed correctly.** A crash in a game's own online code right after the Mac woke
  from sleep had switched FSR 3 off, and Smooth Motion with it. Anvil now reads the game's
  own crash record, keeps FSR 3 on when graphics weren't involved, and says what happened.
  FSR 3 and Smooth Motion are back on for LEGO Star Wars.
- **Clearer check-ups:** a note to save before letting the Mac sleep when a game crashed on
  waking, and a count of graphics effects D3DMetal couldn't build.

Known limits: at 60–80 fps of a game's own nothing is made (a frame between needs two
refreshes of room at 120 Hz). The heaviest scenes are the game's own drawing.

## In 0.57.0

- **The FPS counter is honest**, a **held 80 keeps its spacing better**, heavy frames are
  timed in full, and **Minecraft's PC version** runs through VMware Fusion.

## In 0.55.0

- **Ray tracing at its best** on a standard M-series Mac, **quicker FSR** with the same
  picture, and heavy scenes that keep FSR 3 and Smooth Motion.

## In 0.53.0

- **Epic games:** size before you install, Cancel for a download, Delete for a game.

## In 0.52.0

- **Ray Tracing switch** on each game's page, set up for your Mac by Graphics Prep.
- **No more distortion with reflections on**, and made frames checked before they're shown.

Smooth Motion makes the picture look smoother; controls still respond at the game's own rate.

Full notes open in Anvil the first time you start a new version. You can also click the
version number at the bottom of the sidebar.

## Legacy versions

Older versions stay available in case a new one doesn't suit a game:

- [Anvil 0.65.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.65.0)
- [Anvil 0.64.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.64.0)
- [Anvil 0.63.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.63.0)
- [Anvil 0.62.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.62.0)
- [Anvil 0.61.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.61.0)
- [Anvil 0.60.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.60.0)
- [Anvil 0.59.1 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.59.1)
- [Anvil 0.59.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.59.0)
- [Anvil 0.58.2 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.58.2)
- [Anvil 0.58.1 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.58.1)
- [Anvil 0.58.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.58.0)
- [Anvil 0.57.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.57.0)
- [Anvil 0.55.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.55.0)
- [Anvil 0.53.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.53.0)
- [Anvil 0.52.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.52.0)
- [Anvil 0.50.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.50.0)
- [Anvil 0.49.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.49.0)
- [Anvil 0.48.0 (legacy)](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/tag/v0.48.0)

## Credits

- **Anvil:** created by Jay Chirag Patel ([@yhkyp2ygpv-collab](https://github.com/yhkyp2ygpv-collab)).
  If you clone, fork or build on Anvil, keep this line in your credits and add Jay Chirag
  Patel as a collaborator.
- **Game engine:** Wine with Apple's D3DMetal (Game Porting Toolkit). Anvil downloads it
  from its publisher's engine releases and ships no copy of it.
- **Epic Games:** [legendary](https://github.com/legendary-gl/legendary), the open-source Epic
  client, downloaded from its own releases.
- **Upscaling:** Metal ports of parts of AMD's
  [FidelityFX SDK](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK) (FSR 1 and
  optical flow), © Advanced Micro Devices, Inc., MIT licence.
- **Controllers:** [SDL GameControllerDB](https://github.com/mdqinc/SDL_GameControllerDB),
  zlib licence.

Steam is a trademark of Valve Corporation, and Epic Games is a trademark of Epic Games, Inc.
Anvil isn't affiliated with Valve, Epic Games, Apple, AMD, Mythic or Heroic.

## Build from source

Needs a Mac with Xcode (Swift 5.9 or newer). The Metal toolchain is optional — without it
Anvil's shaders compile the first time they're used:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Build both editions:

```bash
scripts/build_editions.sh
```

| Edition | Output |
|---|---|
| private | `build/Anvil.app` (debug symbols, no self-check) |
| public | `build/public/Anvil.app` and `build/Anvil-<version>.dmg` |

| Folder | What's in it |
|---|---|
| `Sources/Anvil` | The SwiftUI app (`Core` for logic, `UI` for screens) |
| `Native/AnvilMetal` | `libanvil`: Metal shaders, FSR, Smooth Motion, frame pacing, audio, input |
| `Native/Tools` | Graphics Prep, the sound check, and the test suite (`tests`) |
| `Resources` | Icons, entitlements, Minecraft PC setup and bundled data |
| `scripts` | Build scripts |

## License

Anvil is open source under the **[Anvil Source License](LICENSE.txt)**. Copyright © 2026
Jay Chirag Patel.

- **Free to use, change and share.** Build it, fix it, improve it and pass it on, at no
  charge.
- **Clone or fork it? Credit me as a collaborator.** Name *Jay Chirag Patel
  ([@yhkyp2ygpv-collab](https://github.com/yhkyp2ygpv-collab))* as a collaborator in your
  README and in your credits (and in your app's About screen if your version has one), and
  add that GitHub account as a collaborator on your repository.
- **Selling it or publishing it for money needs my permission first.** Open an issue
  titled "Commercial use" on [this repository](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/issues).

Third-party code keeps its own licence: see [THIRD-PARTY.md](THIRD-PARTY.md) (AMD
FidelityFX, MIT licence; SDL GameControllerDB, zlib).
