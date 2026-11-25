# RB Hub — Your Gateway to Retro Gaming

A static, offline-first catalogue and Raspberry Pi setup hub for a real retro-gaming
collection. Every game on the site comes from the inventory PDF; nothing is invented,
nothing is downloaded, and nothing is linked to a ROM site.

---

## Quick start

No build step is needed to view the site.

1. Open `index.html` in a modern browser (Chrome, Edge, Firefox, Safari).
2. That is it. The site uses hash routing, so it also works straight from `file://`.

If you prefer a local server (recommended when editing, so the browser does not cache
the dataset aggressively):

```powershell
# from this folder, with Python installed
python -m http.server 8080
# then visit http://localhost:8080
```

There are no npm packages, no frameworks and no network requests at runtime.
The pixel fonts are system font stacks, so the site also renders offline.

---

## Pages and routes

| Route | Page |
| --- | --- |
| `#/` | Home — hero, Top 5 Classics, platform grid, collection stats, Discover More |
| `#/featured` | Top 5 Classics in detail |
| `#/library` | Game Library — search, platform/genre/decade filters, sorting, load more |
| `#/platforms` | All platforms with counts and emulator summaries |
| `#/platform/:id` | One platform: description, emulator, Pi guidance, full game list |
| `#/game/:id` | One game: facts, description, collection variants, legal sources, Pi notes |
| `#/guide` | Raspberry Pi emulation guide, from bare Pi to working station |
| `#/about` | How the archive was built, exclusions, quirks, sources, disclaimer |
| anything else | 404 page |

Library state is shareable: `#/library?platform=snes&genre=RPG&decade=1990&sort=year-asc`
(also supports `q=` for a search term and `focus=search`).

Keyboard: `/` jumps to the library search box, `Esc` closes the mobile menu,
and the arrow button in the corner returns to the top of the page.

---

## Project layout

```
index.html                 App shell: header, nav, main, footer, CRT layers
assets/
  css/style.css            Full visual system, responsive rules, CRT effects
  js/app.js                Router, pages, filters, sorting, SVG cover generator
  js/rb-data.js            Generated dataset (window.RB_DATA) — do not hand-edit
  img/favicon.svg          Site icon
data/
  inventory.raw.txt        Deduped inventory paths extracted from the PDF
  curated/arcade.json      Hand-written metadata for arcade entries
  curated/nes.json         Hand-written metadata for NES entries
  curated/snes.json        Hand-written metadata for SNES entries
  curated/console.json     Hand-written metadata for Atari/GBA/NDS/N64/LÖVE
  platforms.json           Platform reference data and Pi guidance
  games.json               Generated JSON reference copy of the dataset
tools/
  extract-inventory.ps1    PDF → inventory.raw.txt
  build-data.ps1           Inventory + curated data → rb-data.js + games.json
```

---

## The dataset

The starting point is `C:\Users\Admin\Downloads\List.pdf`, a print of the linked-file
listing for `https://github.com/Shugabuga/RomCollection`. Extracting its link annotations
yields **1,286 unique paths** (the PDF contains genuine duplicate rows, which are collapsed
by path).

Of those paths:

* **57 are not games** — 42 music files, emulator binaries and DLLs, INI/PAL/DIZ metadata,
  save states, battery saves, controller-pak files, a raw EPROM folder, and a directory
  listing text file. Each exclusion is recorded with a reason in the dataset.
* **1,229 ROM files remain**, grouped into **1,171 catalogue games**. Region and revision
  variants of the same game share one catalogue entry, while every original filename stays
  visible in that game's variants table.
* **345 games carry hand-written metadata** (year, developer, publisher, genre,
  description). The rest are marked as filename-derived and unverified rather than guessed.

Platform breakdown as built:

| Platform | Games | Files |
| --- | ---: | ---: |
| Arcade (MAME) | 179 | 217 |
| NES | 621 | 629 |
| SNES | 346 | 358 |
| Atari 2600 | 12 | 12 |
| GBA | 7 | 7 |
| NDS | 1 | 1 |
| N64 | 4 | 4 |
| Homebrew (LÖVE) | 1 | 1 |
| **Total** | **1,171** | **1,229** |

Years span 1975–2012. Titles with no verifiable release year are labelled
**Year unknown** rather than assigned a placeholder.

The Top 5 Classics are fixed to the five requested games: Pac-Man (Arcade),
Donkey Kong (Arcade), Galaga (Arcade), Street Fighter II: The World Warrior (Arcade),
and Mortal Kombat (SNES) — all present in the inventory.

---

## Rebuilding the dataset

The site reads only `assets/js/rb-data.js`. To regenerate it after editing inventory or
curation files:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-data.ps1
```

The build:

1. Reads `data/inventory.raw.txt` (UTF-8, `tree|path` / `blob|path` lines).
2. Loads the four curated JSON files and `data/platforms.json`.
3. Applies exclusions and groups variants by `slug` / `group` keys.
4. Infers genres from title keywords only when no curated genre exists, and flags those
   records as `title-inferred`.
5. Writes `assets/js/rb-data.js` and `data/games.json`, and reports counts plus any
   curated keys that matched no inventory path or any unknown platform ids.

Curated entry keys are inventory paths (`arcade/PACMAN`, `nes/Zelda.nes`,
`snes/Mortal Kombat.sfc`). A full record uses:

```json
{
  "title": "Pac-Man",
  "slug": "pac-man",
  "group": "pac-man",          // groups variants under one game
  "year": 1980,
  "developer": "Namco",
  "publisher": "Midway",
  "genre": "Maze",
  "desc": "...",
  "gameplay": "...",
  "history": "...",
  "notes": "...",
  "official": true,
  "verified": true
}
```

Only `slug` (first record of a group) and `group` (every variant) are structural;
the rest is optional.

---

## Accuracy and labelling rules

* The PDF is the single source of truth. No game is added to the library because it is
  famous; if a title is absent, it is absent.
* Unknown values are written as **Unknown** / **Not available** — never filled in with a
  plausible guess.
* Emulation compatibility is only ever one of:
  **FULLY COMPATIBLE**, **PARTIALLY COMPATIBLE**, **REQUIRES CONFIGURATION**, **UNVERIFIED**.
* Compatibility is assessed at *platform* level, not per-ROM. Every game page carries the
  note that this is a platform-level assessment and not a test result for that file.
* Entries without curation show a **Metadata unverified** badge and an explicit note that
  the record was derived from its filename.

Known limitations, also stated on the About page:

* The zipped SNES No-Intro sets in the source listing cover the alphabet only up to
  roughly letter D; the rest of the SNES library is loose `.sfc`/`.smc` files.
* `Fire Emblem - Sealed Sword` is the Japanese *Fūin no Tsurugi* (The Binding Blade),
  not *The Sacred Stones*.
* Some inventory entries are folders, not files, so their contents cannot be itemised;
  they appear as ROM-set folders.

---

## Artwork

No copyrighted box art or screenshots are bundled. Every cover, hero panel and platform
icon is a procedurally generated inline SVG: a per-platform palette, a mirrored pixel
sprite, a wrapped title and a small "generated cover art" label. The generator lives in
`assets/js/app.js` (`coverArt`, `platformIcon`).

---

## Legal

RB Hub is a **catalogue and setup guide**. It does not host, mirror, embed, stream or link
to ROM files, and it has no download buttons.

The "Where to get this game" panel points only to lawful routes: buying the original
hardware or cartridge, official re-releases and Virtual Console-style storefronts, and
licence-clean homebrew or public-domain releases where those exist. Arcade entries are
explicitly marked as not redistributable when the title is still under copyright.

Game names, platforms and trademarks belong to their respective owners. This is a
non-commercial fan project.

---

## Browser support and accessibility

* Modern evergreen browsers; hash routing keeps `file://` working.
* Mobile navigation with a burger menu, visible focus states, skip link, `aria-pressed`
  on filter tabs, `aria-expanded` on toggles, and labelled controls.
* Layout is fluid from 320 px up to ultrawide; no horizontal overflow at tested widths.
* Neon/CRT effects are decorative and driven by CSS, with `prefers-reduced-motion`
  respected for animation-heavy pieces.
* The game library renders 24 cards at a time and filters the in-memory dataset, so
  1,171 entries stay responsive without pagination round-trips.
