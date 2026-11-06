# SwiftGB

A Game Boy, Game Boy Color and Game Boy Advance emulator for macOS, written from scratch in Swift, with a SwiftUI interface.

The emulation cores are original code, written from public hardware documentation (GBATEK, Pan Docs, ARM and Sharp SM83 references) and checked against public test ROMs. No code from any other emulator is used. SwiftGB ships with **no games and no BIOS**: you add your own ROMs, and the Game Boy Advance BIOS calls are handled natively.

## What it does

- **Game Boy Advance:** ARM7TDMI (ARM and Thumb), full video (all modes, sprites, windows, blending), four timers, four DMA channels, all six sound channels, SRAM / Flash / EEPROM saves, the cartridge clock, and the BIOS services games rely on.
- **Game Boy and Game Boy Color:** SM83 CPU, MBC1/2/3 (with clock)/5, original and Color video, double-speed mode, HDMA, sound, battery saves.
- **App features:** save states (9 slots, plus load/save to any file) and autosave, importing and exporting `.sav` files, rewind, cheats for every GBA cheat device (below), screenshots, MP4 recording, fast-forward from 2× up to unlimited, custom resolution (down to 1 pixel high) and refresh rate (down to 1 a second), rewind that can be switched off, an optional GPU picture renderer, controller support with remapping, a link cable over the local network (GBA up to four players, Game Boy two), and a statistics overlay.
- **Display:** drawn natively at any size up to 16K, any refresh rate up to 240 Hz, with an optional unlimited presentation rate that is independent of emulation speed.

## Requirements

- macOS 26 or later, Apple silicon.
- To build: the Swift 6.2+ toolchain (the Xcode command line tools are enough; Xcode is not required).

## Build and run

```sh
Scripts/build-app.sh            # builds .build/SwiftGB.app (release, ad-hoc signed)
Scripts/build-app.sh --dmg      # also makes .build/SwiftGB-1.0.4.dmg
open .build/SwiftGB.app
```

The app is ad-hoc signed, not notarised. If macOS refuses to open a copy you downloaded, right-click it and choose **Open**, or run `xattr -dr com.apple.quarantine SwiftGB.app`.

Add games with **File ▸ Open ROM…** (⌘O) or drop `.gba`, `.gb` and `.gbc` files onto the window. Settings are on ⌘,.

## Keys

| | |
|---|---|
| A / B | Z / X |
| L / R | A / S |
| Start / Select | Return / Delete |
| D-pad | arrow keys |
| Fast-forward (hold) | Tab |
| Rewind (hold) | W |

Everything can be remapped in Settings ▸ Controls. Commands in the menus all have ⌘ shortcuts: Save State ⌥⌘1–9, Load State ⌘1–9, Screenshot ⌥⌘S, Record ⇧⌘R, Cheats ⌘K, Import Save ⇧⌘I, Export Save ⇧⌘E, Link ⌘J, Statistics ⌥⌘T, Full Screen ⌃⌘F, Window size ⌘= ⌘- ⌘0.

## Tests

`swift test` does not run tests under the command line tools alone, so the tests are headless harness programs instead:

```sh
Scripts/fetch-test-roms.sh      # downloads the public test ROMs (not stored in this repo)
Scripts/run-tests.sh            # runs everything and prints a table
```

The suite covers the GBA CPU, memory, BIOS, DMA and save test ROMs (jsmolka), Blargg's Game Boy CPU, timing and sound ROMs, pixel-exact comparisons with the dmg-acid2 and cgb-acid2 reference pictures, and self-checks for video, sound, timers, link cable, save states, rewind, controls, recording and the app's session engine. A handful of the hardest Game Boy tests (wave-RAM access while a note plays, the OAM corruption bug) are marked as known failures.

## Layout

| | |
|---|---|
| `Sources/GBACore` | the emulation cores (`GB/` holds the Game Boy and Color core) |
| `Sources/GBARender` | Metal drawing of the screen and the library's animated backdrop |
| `Sources/GBAUI` | the SwiftUI app: library, settings, session engine, link, recording |
| `Sources/GBAApp` | the app entry point and menus |
| `Sources/gba-harness`, `gbaui-harness` | the headless test programs |
| `Scripts` | build, icon, test and test-ROM scripts |
| `Branding` | the app icon sources |

## Known gaps

Game Boy sound has three failing Blargg tests (wave RAM quirks), the OAM corruption bug is not modelled, and a few rare Game Boy mappers (MBC6/7, HuC, MMM01) are not supported. GBA timing is approximate (no cartridge prefetch buffer), the BIOS sound-driver calls are not implemented. See *Cheats* for what is and isn't understood. The network link has been tested on loopback and in memory, not yet across two machines.

No licence has been chosen yet.

## Cheats

Press ⌘K while a game is running. The format is detected from the text, or pick one yourself:

| Device | Raw | Encrypted |
|---|---|---|
| GameShark Advance / Action Replay v1-v2 | 8/16/32-bit writes, group writes (`3000cccc`), ROM patches (`6…`), 16-bit if-equal (`D…`), multi-line if-equal (`E0zz…`) | yes |
| Action Replay v3 | 8/16/32-bit writes and fills, pointer writes, add codes, I/O writes, every if/else comparison (equal, not-equal, signed and unsigned less/greater, AND) in one-line, two-line, block and disable forms, "always" skips, slides, end/run-all codes | yes |
| CodeBreaker | `3` `8` `6` writes, `4` slides, `7` `A` conditionals, `D0000020` button check | no (see below) |

Master/hook/ID codes are accepted and ignored (cheats are applied once per frame, no hook needed), as are codes that only act while the device's own button is held (there is none). Not supported, and refused with a reason rather than guessed: CodeBreaker codes that start with `9` (their scrambling isn't published anywhere I could verify) and Action Replay v3 ROM patches (the sources disagree on how the address maps into the ROM). Game Boy / Color cheats are GameShark `01VVLLHH`.

The encryption itself is written from the published description of the algorithm. The two 256-byte lookup tables the devices use to derive new keys after a `DEADFACE` code are fixed constants copied from Parasyte's GPL-licensed GSAcrypt; they sit alone in `Sources/GBACore/CheatTables.swift`. Everything else is original.

Details that were ambiguous in the documentation and so are my best reading: the number of bytes an AR v3 fill writes (`x + 1`), how far a CodeBreaker slide's address steps (twice `iiii`, for 16-bit values), and that a conditional counts code lines.

## Picture on the GPU (experimental)

Settings ▸ Video ▸ *Draw picture on the GPU* hands the Game Boy Advance picture to a Metal compute pass instead of the CPU renderer, which takes roughly a quarter off the CPU load. The CPU renderer stays the default and the reference: a self-test draws 1,500 random video setups (every mode, windows, blending, mosaic, sprites, affine) both ways and requires identical pixels. The differences are inherent: the picture is one frame late, and colour, tile or sprite changes a game makes *during* a frame show from the next frame (register effects such as scrolling and windows are recorded per line and work). The CPU-side game emulation itself cannot run on the GPU.
