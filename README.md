# prepperpi

An offline **grab-and-go / prepper Raspberry Pi** — a self-contained box that sits on the home network, keeps itself updated, and can be unplugged and taken anywhere. It runs its own WiFi hotspot and serves an offline library, maps, radio, an LLM assistant and more to any phone browser.

The entire build is reproduced by a single idempotent script: **[`prepperpi-provision.sh`](prepperpi-provision.sh)**.

## Hardware
- Raspberry Pi 4 (8 GB), Raspberry Pi OS (Debian Trixie, aarch64)
- 512 GB microSD (OS + content); optional separate USB stick for bulk downloads (auto-mounts at `/data`)
- RTL-SDR Blog V4 dongle — RX radio (ADS-B, airband, weather-sat, 433 MHz sensors, HF/VHF/UHF)
- Optional: USB WiFi dongle (wlan1) for simultaneous hotspot + uplink (one on order as of 2026-07-25 — lets the box sit near a window for SDR reception without being tied to wherever the wired network runs)

## Quick start
Flash Raspberry Pi OS, copy this repo onto the Pi, then:

```bash
sudo bash prepperpi-provision.sh
# with optional modules:
sudo ENABLE_MAPS=1 ENABLE_LLM=1 ENABLE_WEBSDR=1 ENABLE_OPENAIP=1 OPENAIP_API_KEY=... bash prepperpi-provision.sh
```

The script is idempotent — safe to re-run. Config vars (hotspot SSID/pass, subnet, interfaces) are at the top. **The admin password is never hardcoded** — leave `BT_PASS="CHANGE_ME"` and the script will prompt for one interactively (or auto-generate and print one if run non-interactively). Afterwards, add content (ZIMs / maps / videos) and do the one interactive step: `sudo tailscale up --hostname=prepperpi --ssh`.

## What it sets up
- **WiFi hotspot** `PrepperPi` on wlan0 (192.168.50.1), with NAT out to eth0 when docked
- **Offline library** — kiwix-serve + a curated ZIM manifest (Wikipedia, Gutenberg, medical, prepper/survival sets, Wikivoyage, Stack Exchanges)
- **Offline maps** — Protomaps/pmtiles + a MapLibre viewer (rough worldwide @ z8 + detailed UK & Poland @ z14, fully offline with bundled fonts)
- **Offline videos** — yt-dlp survival/skills library (curated searches + prepper channels)
- **LLM assistant** — Ollama + `llama3.2:3b`, offline chat page (CPU-only, slow but works)
- **Web-SDR** — [OpenWebRX+](https://github.com/luarvique/openwebrx) (Docker, `slechev/openwebrxplus-softmbe`) — tune the RTL-SDR from any phone browser. Switched 2026-07-25 from mainline OpenWebRX to this community fork for its much larger built-in decoder set (DMR, D-Star, YSF, NXDN, TETRA, DRM, HFDL, VDL2, ACARS, POCSAG, SSTV, FAX, a CW skimmer, a wideband spectrum view). 30 SDR profiles (broadcast FM/Radio 4, airband, London City Approach, marine VHF, Pocsag, 1.25m/2m/6m/70cm amateur + 433MHz ISM, PMR446, NOAA APT weather satellite, ADS-B, 11m CB through 160m + HF/MW/shortwave broadcast bands) and 55 frequency bookmarks (incl. Heathrow's full tower/ground/approach/delivery/ATIS set) are seeded automatically from `openwebrx/settings.json` + `openwebrx/bookmarks.json` in this repo. Login `admin`/`<your BT_PASS>`.
- **OpenAIP aviation data** — `ENABLE_OPENAIP=1` (off by default, needs a free API key from accounts.openaip.net) — UK airspace/navaid/airport data as GeoJSON, refreshed monthly, rendered as a layer in the map viewer. See [Aviation data](#aviation-data) below.
- **LoRa mesh** — [OverMesh](https://github.com/Slofi/overmesh), a combined Meshtastic + MeshCore dashboard — see [Mesh](#lora-mesh) below.
- **E-ink status display** — Waveshare 4.2" panel shows a WiFi auto-join QR code, live status (storage/clients/power/temp), and a portal-URL QR code; auto-refreshes every 15 min, manual refresh button on the control panel
- **Airports DB** — 72k airports searchable offline (OurAirports)
- **Emergency phrasebook** — 27 phrases × 7 languages, offline
- **Control paths** — Bluetooth serial (no network needed), web panel, SSH, web terminal
- **Power modes** — low/full toggle (CPU governor + heavy services)
- **Self-update timer** — nightly apt + yt-dlp + content refresh (runs low-priority)

## Service map
| Port | Service |
|---|---|
| 80 | Portal / landing page (also assistant, phrasebook, maps, airports) |
| 8080 | Kiwix offline library |
| 8081 | Maps (pmtiles) |
| 8082 | Videos |
| 8073 | OpenWebRX+ (web-SDR) *(auth)* |
| 8090 | Control panel — downloads / power / network *(auth)* |
| 7681 | Web terminal (ttyd) *(auth)* |
| 11434 | Ollama (LLM API) |
| 8094 | OverMesh — combined Meshtastic + MeshCore dashboard |

## E-ink display
`ENABLE_EINK=1` (off by default — needs the physical panel wired). Waveshare 4.2" e-Paper shows a WiFi auto-join QR code, SSID/password text backup, live status (storage/clients/power mode/temp, from the same data the portal uses), and a second QR code linking to the portal once connected. Auto-refreshes every 15 min (`prepperpi-eink.timer`); manual refresh via a button on the control panel (`:8090`) — the "rudimentary control" for a panel with no touch/button input of its own (all 8 GPIO pins are used for SPI). Uses `epd4in2_V2` (this is **V2 hardware** — the plain V1 driver hangs forever waiting on the BUSY pin due to inverted polarity between hardware revisions; swap the import if your panel is V1).

## Control
- **Hotspot:** SSID `PrepperPi`, WPA2 pass set by `AP_PASS` at the top of the script (change the default)
- **Admin password** (guards Bluetooth control, web panel :8090, terminal :7681): set at provision time (prompted, or auto-generated if run non-interactively) — never a hardcoded default. Stored in `/etc/prepperpi/bt.conf`.
- **WiFi mode** (single-radio Pi): `prepperpi-mode ap | client <SSID> <PASS> | update` — flips wlan0 between hotspot and client
- **Out-of-band:** a Bluetooth serial control server lets you switch WiFi mode with no network at all (pair with a phone "Serial Bluetooth Terminal" app; commands `ap` / `client SSID PASS` / `update` / `status`)

## Content
- **ZIMs:** `/etc/prepperpi/zim.list` → `/data/zim` (nightly or manual; updater keeps newest dated file per title)
- **Videos:** `/etc/prepperpi/video-topics.list` → `prepperpi-getvideos` (720p mp4, deduped, organised by uploader)
- **Maps:** per-region `.pmtiles` in `/data/maps` — `pmtiles extract <planet> out.pmtiles --bbox=W,S,E,N --maxzoom=14`
  ⚠ **Never extract the whole world at high zoom** — it produces tens of millions of tiles and locks up the Pi. Whole-world only at low zoom (≤8).
- **Separate storage:** `prepperpi-storage /dev/sdX` formats a USB stick ext4 as `/data` (all content dirs live under `/data`, so everything then lands on the stick)

## Aviation data
`ENABLE_OPENAIP=1 OPENAIP_API_KEY=...` — needs a free personal API key from `accounts.openaip.net` (self-service signup, can't be automated). Pulls UK airspace/navaid/airport data via `https://api.core.openaip.net/api/{airspaces,navaids,airports}?country=GB` as GeoJSON, refreshed monthly by `prepperpi-openaip.timer`, written to `/var/www/prepperpi/data/openaip/*.geojson`.

⚠ **Deliberately does NOT scrape skyvector.com or allairportmaps.com** — neither is designed for bulk/automated access and their ToS is unclear on it. OpenAIP is explicitly built for reuse. For the actual official UK airport approach plates (what allairportmaps.com unofficially mirrors), see the NATS eAIP at `nats-uk.ead-it.com` — it's a dynamic JS-driven portal that explicitly warns against bookmarking links (they rotate every 28-day AIRAC cycle), so reliable automation there would need real browser automation (Playwright/Selenium), not a simple cron job. Not yet built — a good candidate for a future module.

- **openflightmaps.org does NOT cover the UK** (checked its live coverage list — ~22 European/African countries, UK absent) — don't reach for it for UK use; it's fine for the Poland/GZD side though.

## LoRa mesh
[OverMesh](https://github.com/Slofi/overmesh) — a unified Flask dashboard for both Meshtastic and MeshCore radios (node mapping, chat/direct messaging, route visualisation, offline map support). Installed as a **per-user systemd service** (not root) at `/home/pi/overmesh`, port moved from its default 8082 to **8094** to avoid clashing with this build's Videos tile. `loginctl enable-linger pi` is required so it keeps running headless without a login session — easy to miss if setting this up by hand outside the provisioning script.

Configure radios from OverMesh's own **Settings** page once attached — it does not read the old `/etc/prepperpi/mesh.conf` format.

⚠ **Superseded 2026-07-25**: this replaces an earlier hand-rolled pair of Meshtastic/MeshCore web interfaces (`prepperpi-mesh-meshtastic.py` / `prepperpi-mesh-meshcore.py`, ports 8093/8094, a dedicated venv at `/opt/prepperpi-mesh/venv`). Those had been verified working against a real Heltec V3 test unit, but OverMesh covers both radio types with more features in one app. If restoring an older device from a stale backup snapshot, don't resurrect the old `prepperpi-mesh-*` services alongside OverMesh — pick one.

## Notes
- **Single-radio Pi:** the hotspot drops while wlan0 joins WiFi to update. A ~£8 USB WiFi dongle (wlan1) enables simultaneous AP + uplink; ethernet handles updates when docked.
- **SDR** is RX-only. The software side is fully ready — it just needs the dongle on a Pi with working USB ports.
