# Craft Suite Setup

Build the [storytold](https://github.com/storytold) **Craft App Suite** (PhotoCraft, VectorCraft, FilmCraft,
LightCraft, PdfCraft, EffectCraft, DesignCraft, FigCraft, WordCraft, SoundCraft, DeckCraft, CADCraft, GridCraft)
from source on a Mac, and open them all from the **ArtCraft Launcher** dashboard.

## Install

```bash
git clone https://github.com/<you>/craft-suite-setup.git ~/Documents/Projects_Folder/craft-suite-setup
cd ~/Documents/Projects_Folder/craft-suite-setup
./run.sh setup
```

`setup` installs what's missing (Apple command line tools, Rust, resvg), clones the launcher and every
app into `~/Documents/Projects_Folder/storytold` (change with `CRAFT_HOME=/path ./run.sh setup`), builds
them, and installs two apps:

| App | What it does |
|---|---|
| **ArtCraft Launcher** | The dashboard: Install, Update and Open every Craft app. Starts the local build server itself. |
| **Craft Suite Setup** | Double-click for a menu: update everything, open, status, reinstall, publish. |

The first build takes a while (often 1-3 hours) and 30-60 GB of disk.

## Everyday use

| Command | |
|---|---|
| `./run.sh` | menu (same as double-clicking Craft Suite Setup) |
| `./run.sh update` | pull updates and any new Craft app, rebuild what changed, open the dashboard |
| `./run.sh open` | open the dashboard |
| `./run.sh status` | checked-out vs built versions |
| `./run.sh install-apps` | reinstall the two Mac apps |
| `./run.sh publish` | push this project to your GitHub (creates a private repo) |

## How it works

craft-launcher's `cargo xtask local sync` builds and packages each app from the checkouts next to it,
`cargo xtask local serve` serves those builds on `127.0.0.1:8787`, and a launcher built with the
`local-mirror` feature installs from there.

Locally built apps are ad-hoc signed, but the launcher only installs apps carrying the ArtCraft team's
Developer ID. [`patches/craft-launcher-local-mirror-signing.patch`](patches/craft-launcher-local-mirror-signing.patch)
skips that one check **only** for builds from the local mirror (loopback, `local-mirror` builds only);
checksums and version checks still run. `run.sh` takes the patch off before updating the launcher and
puts it back after; if upstream changes that code, it stops and tells you.

## Credits

The Craft apps and ArtCraft Launcher are by the ArtCraft team (MIT OR Apache-2.0). The ArtCraft name and
icons are their trademarks; this project only builds their unmodified source and does not include them.
