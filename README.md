# nicks-arch-postinstall-script

Post-install setup for a fresh Arch Linux + KDE Plasma machine.

## Status

**Last confirmed working: 2026-09-11** — Arch Linux, KDE Plasma 6.7.5

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

### Running only part of it

Every step runs by default. To run a subset:

```bash
bash postinstall.sh --only theme      # just the light/dark mode step
bash postinstall.sh --only 13         # the same step, by number
bash postinstall.sh --only 13-15      # light/dark, cursor and decorations
bash postinstall.sh --skip games,wine # everything except those two
bash postinstall.sh --list            # show the step list and exit
bash postinstall.sh --help            # full usage
```

`--only` and `--skip` take comma-separated numbers, names or ranges, and cannot
be combined. Steps always run in script order no matter how you type them, and
an unknown step is an error rather than a silent no-op.

A partial run only asks for `sudo` if a selected step actually needs it — so
`--only panels` or `--only dolphin,imageviewer` runs without a password prompt —
and only downloads the `loose/` payload if step 9 is selected.

Steps are mostly independent, with one link worth knowing: step 15 (window
decorations) follows the light/dark choice from step 13. Run on its own, it
infers the variant from the look-and-feel already in use instead.

## What it does

| # | Step |
|---|------|
| 1 | Adds the Chaotic-AUR repository, if it isn't already configured |
| 2 | Runs a full `pacman -Syu` |
| 3 | Offers to install an AUR helper (yay or paru), unless one is already there |
| 4 | Installs `bluez`/`bluez-utils`, enables and starts `bluetooth.service` |
| 5 | If more than one kernel is installed, points GRUB (or systemd-boot) at the newest one |
| 6 | Installs the KDE/Plasma package set, Discover, Flatpak and the XDG portals; adds Flathub; removes superseded packages; makes Plasma Login Manager the display manager |
| 7 | Asks which browsers you want (Floorp / Firefox / Ungoogled Chromium / Brave), installs them as Flatpaks, and grants Floorp read/write access to `$HOME` |
| 8 | Asks whether to install Thunderbird |
| 9 | Deploys the `loose/` files (`userChrome.css` per browser profile, both Willow themes, reference notes) |
| 10 | Asks whether to install the KDE games |
| 11 | Writes the Dolphin settings |
| 12 | Makes Photos (`koko`) the default image viewer |
| 13 | Asks for light or dark mode, then applies the global theme, color scheme and icons |
| 14 | Sets the Breeze Light cursor theme |
| 15 | Installs both Willow decorations and applies the one matching your light/dark choice |
| 16 | Installs the CUPS/foomatic/gutenprint stack and enables `cups.socket` + `cups.service` |
| 17 | Installs Hunspell/Aspell/Enchant and configures Sonnet for `en_US` |
| 18 | Rebuilds an identical panel + system tray on every monitor at least 1024px wide |
| 19 | Installs Wine (offering to enable `[multilib]` first) |
| 20 | Asks which office suites you want (LibreOffice / Collabora Office), same numbered selection as the browsers |
| 21 | Offers to hide developer/diagnostic entries from the application menu |

It is safe to re-run: package installs use `--needed` and config writes are
idempotent.

## Notes

- **Step 5 touches GRUB as little as possible.** It first reads the existing
  menu and works out which kernel the current `GRUB_DEFAULT` actually boots —
  numeric (`0`), nested numeric (`1>2`), menuentry-id and `saved` forms are all
  understood. If that is already the newest kernel, it changes nothing at all
  and does not regenerate anything. Otherwise it rewrites only the
  `GRUB_DEFAULT` line and regenerates once with
  `grub-mkconfig -o /boot/grub/grub.cfg` (the Arch equivalent of
  `update-grub`), which is unavoidable because `GRUB_DEFAULT` is only read at
  generation time. Nothing else in `/etc/default/grub` is touched, so
  `GRUB_BACKGROUND`, `GRUB_THEME` and the rest are carried through. Both
  `/etc/default/grub` and `/boot/grub/grub.cfg` are backed up to
  `.bak.<timestamp>` first, and if the regenerated menu has lost its
  `background_image`/`set theme=` lines the backup is restored automatically.
- **Step 9** can only place `userChrome.css` in a profile that already exists.
  A freshly installed Flatpak has no profile until you launch it once — if the
  script reports a skip, start the app and re-run.
- **Step 18** needs a running Plasma session. It deletes the existing panels and
  recreates one per screen, so pinned launchers go back to the defaults. The
  layout is copied from the main monitor (the ASUS XG27ACDNG on DP-4):
  bottom, left-aligned, floating, adaptive opacity, `holidaysevents`
  calendar plugin only, and the weather widget hidden in the tray.
  Panel height is inherited from whatever panel is already there, so a rebuild
  never silently shrinks it — a newly created panel would otherwise be 30px,
  thinner than the one Plasma itself creates. 30px is used only when there is
  no existing panel to copy. Force a specific height with
  `PANEL_HEIGHT=44 bash postinstall.sh`.
  Screens narrower than 1024px are skipped so a small capture/TV output
  doesn't get an unusable taskbar. Override with
  `PANEL_MIN_SCREEN_WIDTH=0 bash postinstall.sh`.
- **Light/dark mode** sets the global theme (`org.kde.breeze.desktop` /
  `org.kde.breezedark.desktop`), the color scheme (`BreezeLight` / `BreezeDark`,
  keeping the `#926EE4` accent) and the icon theme (`breeze` / `breeze-dark`),
  and picks Willow Light or Willow Dark for the window decorations. The theme is
  applied without `--resetLayout`, so it does not disturb the panels.
  Both Willow variants are installed either way, so switching later is just a
  System Settings change.
- The **cursor is Breeze Light in both modes**, by design — it does not follow
  the light/dark choice.
- **Plasma Login Manager, not SDDM.** `plasma-login-manager` is installed as
  part of step 6 and enabled as the display manager; `sddm-kcm` is not
  installed. Only one unit can hold the `display-manager.service` alias, so any
  existing display manager is disabled first — and if enabling fails, the
  previous one is put back so the machine is never left without a login screen.
  It is enabled but **not** started, since switching display managers mid-session
  would kill the running desktop: it takes effect on the next reboot. An SDDM
  that is already installed is left on disk, just disabled.
- The **login screen follows the light/dark choice too.** The greeter runs as
  its own system user and reads its own config, not yours, which is why it
  otherwise stays light. The script writes the color scheme, icon theme and
  global theme into `/var/lib/plasmalogin/.config/kdeglobals`, owned by the
  `plasmalogin` user.
- **Chaotic-AUR** is set up before anything is installed, so its packages are
  available to every later step. **No key is hardcoded.** The script downloads
  `chaotic-keyring.pkg.tar.zst`, reads the fingerprints the keyring itself
  declares as trusted (`chaotic-trusted`), prints them, and imports and locally
  signs exactly those — so a key rotation or an added key is picked up
  automatically. It then installs the keyring and mirrorlist from their URLs so
  pacman verifies each `.sig` against the keys just trusted, and the keyring's
  own install hook runs a full populate (which applies revocations). Finally it
  appends a `[chaotic-aur]` section to `/etc/pacman.conf` (backed up first).
  Skipped entirely if `[chaotic-aur]` is already present. This is a third-party
  repository — adding it means trusting its maintainers to ship packages that
  run as root on your machine.
- **Photos instead of Gwenview.** Photos is packaged as `koko`, and as of
  KDE Gear 26.08 it is [proposed as Gwenview's replacement][photos]. The script
  installs `koko` and removes `gwenview` if a previous install left it behind
  (`pacman -Rns`, skipped when it isn't installed, reported rather than forced
  if something still requires it). Add packages to `PKGS_REMOVE` to retire
  others the same way.

[photos]: https://pointieststick.com/2026/09/06/photos-a-proposed-replacement-for-gwenview/

- **An AUR helper is offered, not assumed.** If `yay` or `paru` is already
  installed the step is skipped. Otherwise you pick one or neither — never
  both. Both live in Chaotic-AUR, so this is a normal `pacman` install; if the
  repository isn't available the step falls back to building from the AUR with
  `git` + `makepkg`.
- **Photos as the default image viewer.** The Default Applications KCM keys its
  *Multimedia → Image viewer* dropdown off `image/png` alone, so that entry is
  written to both `[Added Associations]` and `[Default Applications]` in
  `~/.config/mimeapps.list` — which is what makes System Settings read
  "Photos". The other image types Photos handles are set as defaults too, so
  every image actually opens in it. Video types it also claims are left alone.
- **Application menu cleanup (step 21)** is opt-in. It hides these entries:
  Icon Browser, Meld, Qt Assistant, Qt D-Bus Viewer, Qt Linguist, Qt Widgets
  Designer, Qt V4L2 test Utility, Qt V4L2 video capture utility, UXTerm, XTerm
  and YAD settings. Hiding copies the original `.desktop` file into
  `~/.local/share/applications` and sets `NoDisplay=true`, so the program stays
  installed and still works from a terminal, from "Open with" and for file
  associations — it just leaves the menu. Entries that aren't installed are
  counted and skipped. To bring one back, delete its file from
  `~/.local/share/applications`. Edit `MENU_HIDE` to change the list.
- **It finishes with a reboot reminder**, in the terminal and as a desktop
  notification. The notification goes through `notify-send` (from `libnotify`,
  which is in the package list for exactly this) and falls back to
  `kdialog --passivepopup` if that is missing. It reports the failure count when
  something went wrong, and is skipped silently when there is no graphical
  session — over SSH or from a bare TTY — rather than erroring.
- `cups-browsed` is installed but left disabled, matching the reference system.
