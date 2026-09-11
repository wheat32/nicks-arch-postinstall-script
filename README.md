# nicks-arch-postinstall-script

Post-install setup for a fresh Arch Linux + KDE Plasma machine.

## Running it

Run as your **normal user** (it calls `sudo` itself):

```bash
curl -fsSL https://raw.githubusercontent.com/wheat32/nicks-arch-postinstall-script/main/postinstall.sh | bash
```

or from a clone:

```bash
bash postinstall.sh
```

The script always downloads the `loose/` payload from GitHub, so it works
standalone — a local copy of those files is never assumed.

Set `REPO_BRANCH=somebranch` to pull the payload from a different branch.

## What it does

| # | Step |
|---|------|
| 1 | Installs `bluez`/`bluez-utils`, enables and starts `bluetooth.service` |
| 2 | If more than one kernel is installed, points GRUB (or systemd-boot) at the newest one |
| 3 | Installs the KDE/Plasma package set, Discover, Flatpak and the XDG portals; adds Flathub |
| 4 | Asks which browsers you want (Floorp / Firefox / Ungoogled Chromium / Brave) and installs them as Flatpaks |
| 5 | Grants Floorp read/write access to `$HOME` |
| 6 | Asks whether to install Thunderbird |
| 7 | Deploys the `loose/` files (`userChrome.css` per browser profile, the Willow Dark theme, reference notes) |
| 8 | Asks whether to install the KDE games |
| 9 | Writes the Dolphin settings |
| 10 | Sets the Breeze Light cursor theme |
| 11 | Installs and applies the Willow Dark window decoration |
| 12 | Installs the CUPS/foomatic/gutenprint stack and enables `cups.socket` + `cups.service` |
| 13 | Installs Hunspell/Aspell/Enchant and configures Sonnet for `en_US` |
| 14 | Rebuilds an identical panel + system tray on every monitor at least 1024px wide |
| 15 | Installs Wine (offering to enable `[multilib]` first) |
| 16 | Asks whether to install LibreOffice, Collabora Office, both, or neither |

It is safe to re-run: package installs use `--needed` and config writes are
idempotent.

## Notes

- **Step 2** edits `GRUB_DEFAULT` in `/etc/default/grub` and then regenerates
  the menu with `grub-mkconfig -o /boot/grub/grub.cfg` (the Arch equivalent of
  `update-grub`). The old file is backed up to `/etc/default/grub.bak.<timestamp>`.
- **Step 7** can only place `userChrome.css` in a profile that already exists.
  A freshly installed Flatpak has no profile until you launch it once — if the
  script reports a skip, start the app and re-run.
- **Step 14** needs a running Plasma session. It deletes the existing panels and
  recreates one per screen, so pinned launchers go back to the defaults. The
  layout is copied from the main monitor (the ASUS XG27ACDNG on DP-4):
  bottom, left-aligned, floating, adaptive opacity, `holidaysevents`
  calendar plugin only, and the weather widget hidden in the tray.
  Panel height is left at the Plasma default.
  Screens narrower than 1024px are skipped so a small capture/TV output
  doesn't get an unusable taskbar. Override with
  `PANEL_MIN_SCREEN_WIDTH=0 bash postinstall.sh`.
- `cups-browsed` is installed but left disabled, matching the reference system.
