# Monitor Switcher

Share your monitors between a **Mac** and a **Windows PC** and have them follow your keyboard and mouse.

- Move your keyboard and mouse to the PC and start using it → every monitor switches to the PC.
- Move your keyboard **or** mouse back to the Mac → the monitors come back right away.
- A keyboard that simply falls asleep never switches anything: the PC app tells the Mac when you actually start using the PC.

It is two small apps that work as a pair over your local network:

| | Mac | Windows |
|---|---|---|
| Lives in | Menu bar (monitors icon) + a window | Notification area (tray) + a window |
| Starts | At login | With Windows |
| Job | Watches the Bluetooth keyboard/mouse, decides who gets the monitors, switches inputs over DDC/CI where it can | Reports when you use the PC, switches inputs over DDC/CI through the PC's own cables |
| Updates | Automatically, from GitHub Releases | Automatically, from GitHub Releases |

## Requirements

- A Mac with **Apple silicon**, macOS 14 or later. DDC/CI uses Apple silicon's display APIs, so Intel Macs aren't supported.
- Windows 10 or 11 with .NET Framework 4.8 (built in).
- Monitors with **DDC/CI** enabled (most are; some have a DDC/CI switch in their menu).
- A keyboard and/or mouse that switches between hosts and connects to the Mac over **Bluetooth**. The app sees when they disconnect from and reconnect to the Mac.
- The Mac and the PC on the same local network.

## Install

1. Download `MonitorSwitcher-macOS.zip` from the [latest release](../../releases/latest), unzip it and move **Monitor Switcher** to Applications.
   The app is not notarized, so the first time right-click it and choose **Open** (or allow it under System Settings → Privacy & Security).
2. On the PC, get `MonitorSwitcher.exe` from the same release, or open `http://<your Mac's IP>:47801` in a browser — the Mac app serves it too.
   Run it. If Windows shows “Windows protected your PC”, choose **More info → Run anyway**. It installs itself into `%LOCALAPPDATA%\Programs\MonitorSwitcher`, adds a Start menu shortcut and starts with Windows.
   Allow it on private networks if Windows Firewall asks.
3. On the Mac: **PC → Find PCs → Pair**, then press **Allow** on the PC. If macOS asks whether Monitor Switcher may find devices on your local network, allow it.

## Set up

**Devices.** On first launch the Mac app picks the Bluetooth keyboards and mice that are connected. Change the selection on the **Devices** page.

**Monitors.** Every external monitor gets a switching method and two input codes (one for the Mac, one for the PC):

| Method | What happens | When to use it |
|---|---|---|
| **DDC from Mac** | The Mac sends the monitor an Input Source command (VCP `0x60`) | The Mac's connection passes DDC (most direct cables and the Mac mini's HDMI port) |
| **DDC via PC** | The Mac asks the PC app to send the command over the PC's cable | The Mac's adapter or dock doesn't pass DDC (many USB-C → HDMI adapters don't) |
| **Cut Mac signal** | The Mac turns its output to the monitor off; the monitor's auto source switch finds the PC | Last resort — many monitors handle it unreliably |
| **Don't switch** | — | Monitors that only the Mac uses |

New monitors default to **DDC from Mac** when the Mac gets a DDC reply, otherwise to **DDC via PC** (or **Cut Mac signal** if no PC is paired). The page tells you when the Mac can't reach a monitor over DDC but the PC can.

**Input codes.** Standard MCCS codes are DisplayPort 1 = `15`, DisplayPort 2 = `16`, HDMI 1 = `17`, HDMI 2 = `18`, USB-C = `27`, but vendors don't always follow them (Samsung often uses `5` and `6`). To find the right ones, each monitor card shows the input it is showing right now:

1. While the monitor shows the Mac, press **Use for Mac**.
2. Switch the monitor to the PC with its own buttons, press **Refresh**, then **Use for PC**.

Press **Test** to hand a monitor to the PC for five seconds and back.

## How switching is decided

**To the PC** — when a selected device has disconnected from the Mac *and* the PC app reports keyboard/mouse input on the PC. Without a paired PC, the Mac falls back to a heuristic: all selected devices left and the Mac was in use shortly before (so devices that fall asleep don't count).

**Back to the Mac** — as soon as any selected device reconnects to the Mac.

**Manually** — the Mac menu bar, the Windows tray (“Monitors → Mac / PC”), or shortcuts:

```bash
open -g monitorswitcher://pc      # also: mac, toggle, restore, auto-on, auto-off, update
```

## Updates

Every push to `main` that changes the code builds both apps on GitHub Actions and publishes a release (`.github/workflows/release.yml`). Both apps check the latest release every few hours and install it automatically; each also has an **Update** button and a switch to turn automatic installs off. Forks can point the apps at their own releases: `MSUpdateRepository` in `Packaging/Info.plist` and `UpdateRepository` in the Windows `.csproj`.

## Network

| Port | Listens | For |
|---|---|---|
| TCP 47800 | PC | Commands from the Mac (`/status`, `/input`, `/mode`, `/log`, …) |
| UDP 47800 | PC | Answers the Mac's `MSW-DISCOVER` broadcast |
| TCP 47801 | Mac | Requests from the PC (`/pc-input`, `/switch`, `/status`) and the `.exe` download page |

Pairing has to be approved on the PC and creates a random key; every other request must carry it. Everything stays on your local network.

## Troubleshooting

- **A monitor doesn't switch from the Mac** — the adapter or dock probably blocks DDC. Use **DDC via PC**, or connect that monitor to a port that passes DDC.
- **The PC isn't found** — check that Monitor Switcher runs on the PC and Windows Firewall allows it on private networks, or pair by IP address.
- **The Mac can't reach the PC after an update** — macOS may ask for local network access again; allow it.
- **A monitor is stuck without the Mac's signal** — Settings → **Bring all monitors back**, or run `"/Applications/Monitor Switcher.app/Contents/MacOS/MonitorSwitcher" --restore`.
- **See what the app sees** — `MonitorSwitcher --probe` lists displays, their DDC status and input devices.

Logs: `~/Library/Logs/MonitorSwitcher.log` on the Mac, `%LOCALAPPDATA%\MonitorSwitcher\log.txt` on the PC (also readable from the Mac through the PC app).

## Build from source

You need the Xcode Command Line Tools and the .NET SDK (`brew install dotnet`) — the Windows app is built on the Mac too.

```bash
scripts/build.sh            # build/Monitor Switcher.app, build/MonitorSwitcher.exe, build/MonitorSwitcher-macOS.zip
scripts/build.sh --install  # …and install into /Applications and launch
```

The version comes from the `VERSION` file (`major.minor`); release builds add the GitHub Actions run number.

## Project layout

- `Sources/MonitorSwitcher/Core` — DDC/CI over Apple silicon's `IOAVService`, turning display outputs on and off, watching HID devices through IOKit (no Input Monitoring permission needed), networking, self-update.
- `Sources/MonitorSwitcher/Model` — settings and the switching logic.
- `Sources/MonitorSwitcher/UI` — the SwiftUI interface.
- `windows/MonitorSwitcher.Win` — the Windows app (WPF + tray icon, DDC/CI through `dxva2.dll`).
- `scripts` — build script and icon generator.
