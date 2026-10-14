# Anvil — Mac Game Launcher

**Play your Windows games from Steam and Epic Games on a Mac, and have them run smoother.**

If you ever wanted to play games on your Mac but couldn't because they weren't made for Mac,
Anvil fixes that. It installs and runs Windows games on Apple silicon Macs, then tunes each
one while you play: sharper upscaling, extra frames in heavy scenes, even frame pacing,
working controllers and surround sound.

### [⬇ Download Anvil 0.48.0](https://github.com/yhkyp2ygpv-collab/Mac-Game-Launcher/releases/latest)

Free · Apple silicon (M1 or later) · macOS 14 Sonoma or newer

---

## Features

- **Steam and Epic Games** — sign in, see your library, install and play.
- **AMD FSR upscaling in every game** — FSR 1 or FSR 3 to your display's full resolution,
  with textures sharpened to match. DLSS games can use Apple's MetalFX instead.
- **Smooth Motion** — in heavy scenes, a frame made between each two of the game's own:
  30 fps of its own is shown as about 60.
- **Steady frame pacing** — even frame times on ProMotion and regular displays, so 40 fps
  feels like 40 and not like stutter.
- **Auto-Tune** — measures each game on your Mac and picks its settings and engine for you.
- **Graphics Prep** — Anvil's upscaling and frame generation are compiled and tested on your
  Mac before the game starts, and the game's shader cache is kept between sessions.
- **Controllers** — Xbox, PlayStation and Switch Pro controllers, with a built-in tester.
- **3D surround sound** — spatial audio for every game, and stereo turned into surround.
- **Save Guard** — automatic backups of your saves.
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
| Frame generation (Smooth Motion) | ✅ | — | — |
| Frame pacing for ProMotion displays | ✅ | — | — |
| Automatic per-game tuning | ✅ | — | — |
| In-game controller fixes (Switch Pro, input lag) | ✅ | — | — |
| 3D surround sound | ✅ | — | — |
| Save backups | ✅ on your Mac | — | ✅ cloud sync |
| Plain-English problem reports | ✅ | — | — |
| Open source | — | ✅ | ✅ |
| Runs on | Apple silicon Macs | Macs | Mac, Windows, Linux |

<sub>— means not listed in that project's README (October 2026). Heroic also supports more
stores and Intel Macs (through CrossOver). If something here is out of date, tell me in the
feedback form below.</sub>

## Install

1. Download `Anvil-0.48.0.dmg` from
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
analytics or tracking.

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

## What's new in 0.48.0

- **Smooth Motion rebuilt.** Each made frame is now built between two real frames instead
  of guessed ahead, so it stays right when you turn or stop. Frames are shown evenly.
- **Works in heavy scenes from 15 fps.** In Anvil's heavy test scene, frames shown went
  from about 35 to about 69 a second, 1% lows from 20 to 34 fps, and the worst gap between
  frames from 50 to about 30 ms.
- **No more switching on and off** as the frame rate swings.
- **Heavy-scene report.** The Doctor now names the three GPU passes that cost the most, so
  you can see what makes a scene slow.

Full notes open in Anvil the first time you start a new version. You can also click the
version number at the bottom of the sidebar.

## Credits

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

## License

Anvil is free to download and use, but it is **not open source**, and its source code isn't
published here. Copyright © 2026 Jay Chirag Patel. All rights reserved. See
[LICENSE.txt](LICENSE.txt).
