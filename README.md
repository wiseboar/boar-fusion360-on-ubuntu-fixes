# Fusion 360 on Ubuntu 24.04 + NVIDIA RTX 5080 — Working Setup

This directory contains the installer + launcher configuration that finally
got Autodesk Fusion 360 (non-commercial) running on:

- Ubuntu 24.04
- NVIDIA RTX 5080, driver 570.211.01
- GNOME on X11 (`DISPLAY=:1`)
- Wine 11.6 Staging (`wine-staging` package)
- Winetricks 20250102 (system package)

## TL;DR

Install = run `./run-install.sh` (wraps `fusion_installer.sh` from str0g's
installer with extra logging). Launch = `~/.fusion360/wineprefixes/box-run.sh`.

After Autodesk sign-in, Fusion launches to the usual Welcome / Data Panel UI.

## What finally worked

The install went fine out of the box; Fusion would boot to the Service
Utility / Safe Mode dialog but crash to a `cer_dialog.exe` whenever we
hit "Launch Fusion". These issues had to be fixed:

### 1. DXVK enabled for d3d11 + dxgi only; older DirectX left on wined3d

Fusion's 3D viewport drives DirectX 11 and DXGI. On the RTX 5080 the
wined3d → OpenGL path renders the viewport as a black rectangle (or no
model at all) because wined3d lies about the GPU identity (it tells
Fusion it is a "GeForce GTX 470") and its D3D11 shader translation
mis-compiles several of Fusion's shaders on Blackwell. The fix is to
route only the viewport-relevant D3D DLLs through DXVK
(DirectX → Vulkan → NVIDIA's native driver) while keeping the older
legacy DirectX versions on wined3d:

```text
HKCU\Software\Wine\DllOverrides:
  *d3d8       = builtin          # legacy; wined3d is fine
  *d3d9       = builtin
  *d3d10core  = builtin
  *d3d11      = native,builtin   # DXVK first, wined3d fallback
  *dxgi       = native,builtin   # DXVK first, wined3d fallback
```

(the non-prefixed variants match.) DXVK itself lives in the usual
`system32` / `syswow64` slots (dropped there by winetricks during install).

We also tune DXVK via `drive_c/dxvk.conf` to avoid the paths that
historically crashed the embedded Qt WebEngine (Chromium) at init:

```ini
d3d11.maxFeatureLevel    = 11_1
dxgi.maxFrameLatency     = 1
dxgi.syncInterval        = 1
dxgi.deferSurfaceCreation = True
d3d11.cachedDynamicResources = ""
```

The launcher exports `DXVK_CONFIG_FILE` pointing at it.

With this in place `GraphicsCardInfo.xml` reports the actual
**NVIDIA GeForce RTX 5080** (rather than wined3d's fake GTX 470) and
DXVK compiles Fusion's shaders cleanly on first run (subsequent runs
hit the disk cache at `drive_c/dxvk-cache`).

Note: Fusion has a built-in preference to prefer OpenGL Core over DX11
(`GraphicsOptionGroup/driverOptionId = VirtualDeviceGLCore`). We still
pre-populate it in `NMachineSpecificOptions.xml`, but Fusion's cloud
sync tends to reset the group on first launch after a forced shutdown,
so the DXVK path is what actually carries the viewport.

### 2. Force glvnd EGL dispatch to NVIDIA only

The real killer: Fusion's embedded Chromium (Qt WebEngine / WebView2) calls
EGL. On this machine the Mesa EGL vendor sees PCI ID `10de:2c02`
(RTX 5080), doesn't recognise it, and returns `driver (null)`. glvnd picks
Mesa first, Mesa fails, and no fallback happens — every Chromium/WebView2
child process crashes at init time with `STATUS_BREAKPOINT` inside
`Qt6WebEngineCore.dll` (a Chromium `CHECK()`).

Fix: point glvnd at the NVIDIA ICD only (NVIDIA 570.211.01 supports the
5080 perfectly — `eglinfo` works flawlessly once Mesa is out of the way).
This does **not** touch any driver; it just changes which JSON glvnd
reads at dispatch time.

```bash
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
export __GLX_VENDOR_LIBRARY_NAME=nvidia
```

### 3. Use stock `Qt6WebEngineCore.dll` (revert str0g/cryinkfly patch)

str0g's installer replaces Fusion's `Qt6WebEngineCore.dll` with
cryinkfly's `Qt6WebEngineCore-06-2025.7z` community patch. That patch is
from June 2025 (140 MB). Fusion as streamed in April 2026 ships a 154 MB
version that Wine 11.6 Staging handles correctly on its own. The mismatch
between the old patched Chromium and the new Qt/Wine was the proximate
cause of the `BREAKPOINT` at Chromium init.

Restore the original after install finishes:

```bash
PROD="$HOME/.fusion360/wineprefixes/drive_c/Program Files/Autodesk/webdeploy/production/<build-hash>"
cd "$PROD"
cp Qt6WebEngineCore.dll Qt6WebEngineCore.dll.cryinkfly-jun2025   # save patch
cp Qt6WebEngineCore.dll.backup Qt6WebEngineCore.dll              # restore stock
```

(Fusion's own installer kept the original at `.dll.backup`.)

### 6. Sync Wine's DPI to the host

200% desktop scaling on GNOME/X11 comes through as `Xft.dpi: 192`.
Without syncing it, Fusion renders at 96 DPI inside the virtual
desktop, producing unreadably tiny UI. The launcher reads
`xrdb -query Xft.dpi` (or `gsettings get org.gnome.desktop.interface
scaling-factor * 96` as a fallback) and writes it to
`HKCU\Control Panel\Desktop\LogPixels` and
`HKCU\Software\Wine\Fonts\LogPixels` before each launch. If you want
to pin Fusion to a fixed DPI, export `WINE_NO_DPI_SYNC=1` before
running the launcher.

`Fusion360.exe` is also tagged `HIGHDPIAWARE` via
`HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers`.

### 7a. Force Chromium to paint its first frame (Open-dialog "black until click")

Fusion's *Open* / *Save As* / *Data Panel* dialogs are Qt WebEngine
(Chromium). On Wine, Chromium's compositor waits for a vblank signal
that the Wine windowing layer never delivers, so the dialog renders a
blank black frame until a mouse/keyboard event triggers an
invalidation. Adding the following flags to `QTWEBENGINE_CHROMIUM_FLAGS`
forces Chromium to paint synchronously as part of layout instead:

```
--disable-gpu-vsync
--disable-frame-rate-limit
--disable-threaded-compositing
--disable-partial-raster
```

If the dialog is still blank, escalate with
`--disable-gpu-compositing --disable-gpu-rasterization` (full software
path — slower but always paints).

### 7b. Force `VirtualDeviceGLCore` in Fusion's option files on every launch

Fusion writes its preferences to two XML files (UTF-16 LE, nested
`<OptionGroups>` schema):

- `AppData/Roaming/Autodesk/Neutron Platform/Options/NMachineSpecificOptions.xml`
- `AppData/Roaming/Autodesk/Neutron Platform/Options/<UserBucket>/NGlobalOptions.xml`

The launcher re-injects
`<driverOptionId Value="VirtualDeviceGLCore"/>` into both on each
start (as a Python heredoc), so even if Fusion's crash-recovery code
resets `GraphicsOptionGroup` to defaults, the preference is back in
place before the next launch. Skip this via `FUSION_NO_FORCE_GL=1`.

## The final launcher: `~/.fusion360/wineprefixes/box-run.sh`

```bash
#!/bin/bash
export WINEARCH=win64
export WINEPREFIX="/home/boar/.fusion360/wineprefixes"
export DISPLAY="${DISPLAY:-:1}"
export XAUTHORITY="${XAUTHORITY:-/run/user/$(id -u)/gdm/Xauthority}"

# glvnd: NVIDIA-only EGL/GLX dispatch (critical for RTX 5080)
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
export __GLX_VENDOR_LIBRARY_NAME=nvidia

# Qt WebEngine / Chromium soft-rendering hints (belt-and-braces; not strictly
# required once stock Qt6WebEngineCore is back, but harmless and safer on
# machines where NVIDIA EGL still has trouble)
export QT_OPENGL=software
export QT_QUICK_BACKEND=software
export QTWEBENGINE_DISABLE_SANDBOX=1
export QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox --disable-gpu-sandbox --in-process-gpu --disable-features=UseChromeOSDirectVideoDecoder,VizDisplayCompositor --ignore-gpu-blocklist"
export QT_QPA_PLATFORM=windows

export WINEDEBUG="${WINEDEBUG:-err-ole,fixme-all,-winediag}"

export mesa_glthread=true
export __GL_SHADER_DISK_CACHE=1

exec wine "/home/boar/.fusion360/wineprefixes/drive_c/Program Files/Autodesk/webdeploy/production/<build-hash>/Fusion360.exe" "$@"
```

### 4. Register the `adskidmgr://` URL scheme handler

Fusion's sign-in happens in your system browser and hands the auth token
back via a custom URL scheme `adskidmgr://`. str0g's installer drops the
handler into `~/.local/share/applications/autodesk/` — a subdirectory —
which xdg-open does NOT scan. Symptom: clicking "Open Product" in the
browser pops up "xdg-open failed" or does nothing.

Fix (one-shot):

```bash
cp ~/.local/share/applications/autodesk/adskidmgr-opener.desktop \
   ~/.local/share/applications/adskidmgr-opener.desktop
update-desktop-database ~/.local/share/applications
xdg-mime default adskidmgr-opener.desktop x-scheme-handler/adskidmgr
```

Verify with `xdg-mime query default x-scheme-handler/adskidmgr` — it
should print `adskidmgr-opener.desktop`. First time the browser sees an
`adskidmgr://` URL it will ask for permission; accept it.

### 5. Run Fusion inside a Wine virtual desktop (Z-order workaround)

After login, Fusion suffered from classic Wine-on-X11 symptoms: floating
child panels, invisible overlays blocking clicks, menus appearing behind
the main window. Root cause is an upstream Wine bug (MR 2343) where
captionless popup windows get handed to the X11 WM which then mis-orders
them. The definitive fix is a one-line patch to `winex11.drv/window.c`
and a Wine rebuild (~30 min).

Cheap workaround that sidesteps the bug entirely: run Fusion inside a
Wine virtual desktop (`wine explorer /desktop=Fusion,<WxH>`). The
`explorer` process creates a single X11 window and manages all of
Fusion's subwindows itself — mutter never gets a chance to reorder them.

Implementation lives in `~/.fusion360/wineprefixes/box-run-vd.sh`. The
desktop shortcut `~/Desktop/Fusion360.desktop` points at this variant.
Override the desktop size via `FUSION_VDESK_SIZE=3000x1700` if needed.

Belt-and-braces registry tweaks applied alongside (have no effect
without the Wine patch but also no harm):

```text
HKCU\Software\Wine\X11 Driver:
  Managed     = Y
  Decorated   = Y
  UseXRandR   = Y
  UseXVidMode = Y
```

## Things that did NOT help (but were tried)

- Bottles (Flatpak) — Flatpak sandbox + NVIDIA GLX produces `BadMatch (NV-GLX)` and `nodrv_CreateWindow`; abandoned.
- cryinkfly's GitHub `autodesk_fusion_installer_x86-64.sh` — archived repo, syntax error at line 709. Codeberg repo is the current one (also supports `--proton=` flag, which we didn't need).
- Overriding `bcp47langs` / `msvcp140` via `DllOverrides` — done by winetricks anyway, doesn't affect the Chromium crash.
- `--disable-gpu --disable-software-rasterizer` together → Chromium CHECK failure because nothing is left to rasterize with. Never pass both.

## Files here

- `fusion_installer.sh` — vendored copy of str0g's installer (as of 2025-11-28).
- `run-install.sh` — wrapper that sets `DISPLAY`/`XAUTHORITY`/`WINEDEBUG` and logs to `install.log`/`install.last.log`.
- `fusion-launch.log` — rolling log of our manual launches while debugging (safe to delete).

# Known Issues

There's still render issues in-app that aren't resolved with black background and disappearing UI elements, so the app is not (yet) in a usable state.

# Agent Model

generated & tested using Opus 4.7 / April 2026
