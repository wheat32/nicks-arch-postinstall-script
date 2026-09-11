#!/usr/bin/env bash
#
# nicks-arch-postinstall-script
#
# Post-install setup for a fresh Arch Linux + KDE Plasma system.
# Run as your normal user (NOT root) -- it calls sudo where it needs to.
#
#   bash postinstall.sh
#
set -uo pipefail

REPO_OWNER="wheat32"
REPO_NAME="nicks-arch-postinstall-script"
REPO_BRANCH="${REPO_BRANCH:-main}"
TARBALL_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_BRANCH}"

WORKDIR=""
LOOSE=""
FAILURES=()

# Chaotic-AUR bootstrap. No key is hardcoded: the keyring package declares its
# own trusted fingerprints, so they are read out of it at run time and a key
# rotation is picked up automatically.
CHAOTIC_CDN="https://cdn-mirror.chaotic.cx/chaotic-aur"

# ---------------------------------------------------------------- helpers ---

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'

step()  { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn()  { printf '    %s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()   { printf '    %s%s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }

fail() { err "$*"; FAILURES+=("$*"); }

# Post a desktop notification, if there is a desktop to post it to. Silently
# does nothing over SSH or from a bare TTY.
notify_desktop() {
    local title="$1" body="$2"

    [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || return 1
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || return 1

    if command -v notify-send >/dev/null 2>&1 \
       && notify-send --app-name="Arch post-install" --icon=system-reboot \
                      --urgency=normal "$title" "$body" >/dev/null 2>&1; then
        return 0
    fi
    # kdialog is guaranteed by the package list; notify-send is not.
    if command -v kdialog >/dev/null 2>&1 \
       && kdialog --title "$title" --passivepopup "$body" 20 >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

cleanup() { [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

# -r on /dev/tty is not enough: the file can exist and still fail to open when
# there is no controlling terminal. Actually try it.
have_tty() { { : </dev/tty; } 2>/dev/null; }

# Read an application's display name out of its .desktop file, so a name the
# project may change upstream is never hardcoded. Falls back to $2.
desktop_app_name() {
    local file="$1" fallback="$2" dir name=""
    for dir in /usr/share/applications /usr/local/share/applications \
               "$HOME/.local/share/applications" \
               /var/lib/flatpak/exports/share/applications; do
        [[ -r "$dir/$file" ]] || continue
        name="$(awk -F= '
            /^\[Desktop Entry\]/ { e = 1; next }
            /^\[/                 { e = 0 }
            e && /^Name=/         { sub(/^Name=/, ""); print; exit }
        ' "$dir/$file")"
        [[ -n "$name" ]] && break
    done
    printf '%s\n' "${name:-$fallback}"
}

# Present a numbered menu and collect a space-separated selection ("1 3"), or
# nothing for none. Results land in SELECTED as 1-based indices, de-duplicated
# and in the order the user typed them.
SELECTED=()
ask_multi() {
    local names=( "$@" ) i n x seen picks=()
    SELECTED=()

    echo
    for i in "${!names[@]}"; do
        printf '      %d) %s\n' $((i + 1)) "${names[$i]}"
    done
    echo
    info "Enter the number(s) you want, separated by spaces (e.g. \"1\" or \"1 2\"),"
    info "or leave it blank for none."
    read -r -p "    Selection: " -a picks </dev/tty

    for n in "${picks[@]}"; do
        if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#names[@]} )); then
            warn "Ignoring '$n'."
            continue
        fi
        seen=0
        for x in "${SELECTED[@]}"; do [[ "$x" == "$n" ]] && seen=1; done
        (( seen )) || SELECTED+=( "$n" )
    done
}

# Ask a yes/no question. Default is "no" unless $2 is "y".
ask_yn() {
    local prompt="$1" default="${2:-n}" reply hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    read -r -p "    $prompt $hint " reply </dev/tty
    reply="${reply:-$default}"
    [[ "${reply,,}" == y* ]]
}

# Write a key=value into a KDE config file/group without clobbering the rest.
kw() { kwriteconfig6 --file "$1" --group "$2" --key "$3" "$4"; }

# ------------------------------------------------------- package selection ---

# Everything from both of Nick's package dumps, de-duplicated, minus the
# kde-games entries (those live in PKGS_GAMES and are opt-in).
PKGS_BASE=(
    # --- explicitly requested ---
    discover flatpak
    xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-kde
    # --- KDE applications / utilities ---
    ark dolphin dolphin-plugins filelight koko isoimagewriter kate kcalc
    kcharselect kclock kcron kdf kdialog kjournald kolourpaint konsole kup ksystemlog
    libnotify
    ktorrent kwalletmanager kweather okular partitionmanager sweeper
    kamera kamoso kdeconnect kdegraphics-mobipocket kdegraphics-thumbnailers
    kdenetwork-filesharing kio-admin kio-extras krdc ffmpegthumbs
    signon-kwallet-extension kaccounts-integration
    # --- KDE frameworks ---
    frameworkintegration kcontacts kdeclarative kded kdesu kholidays
    # --- Plasma shell / workspace ---
    plasma-desktop plasma-workspace plasma-workspace-wallpapers plasma-integration
    plasma5support libplasma plasma-activities plasma-activities-stats
    plasma-browser-integration plasma-disks plasma-firewall plasma-nm plasma-pa
    plasma-systemmonitor plasma-thunderbolt plasma-vault plasma-wayland-protocols
    kdeplasma-addons systemsettings kinfocenter kmenuedit kscreen libkscreen
    kscreenlocker kwrited krdp kglobalacceld kactivitymanagerd ksystemstats
    libksysguard kpipewire milou powerdevil knighttime layer-shell-qt
    drkonqi polkit-kde-agent kwallet-pam plasma-login-manager kgamma spectacle
    kde-cli-tools kwayland kwayland-integration flatpak-kcm plymouth-kcm
    print-manager
    # --- window manager + decorations ---
    kwin kwin-x11 kdecoration aurorae
    # --- themes / look & feel ---
    breeze breeze-gtk breeze-cursors breeze-plymouth kde-gtk-config
    qqc2-breeze-style oxygen oxygen-cursors oxygen-sounds ocean-sound-theme
    # --- bluetooth ---
    bluedevil bluez bluez-utils
)

PKGS_GAMES=( kbreakout kmahjongg kmines kpat ksudoku libkdegames )

# Packages to take back off the system if an installer or an earlier setup left
# them behind. Nothing here is ever installed by this script.
#
#   gwenview    -- superseded by the koko package, which is proposed as its
#                  replacement as of KDE Gear 26.08.
#   pavucontrol -- a standalone GTK mixer some installers add by name (the
#                  EndeavourOS one does). Unrelated to plasma-pa, which is what
#                  actually provides the tray volume applet, the Sound page in
#                  System Settings and the volume media keys.
PKGS_REMOVE=( gwenview pavucontrol )

PKGS_PRINT=(
    cups cups-browsed cups-filters cups-pdf
    foomatic-db foomatic-db-engine foomatic-db-ppds
    foomatic-db-gutenprint-ppds foomatic-db-nonfree foomatic-db-nonfree-ppds
    ghostscript gsfonts gutenprint system-config-printer python-pycups
)

# Sonnet (the KDE spell-checking framework) backs onto hunspell/aspell/enchant.
PKGS_SPELL=( hunspell hunspell-en_us aspell enchant )

PKGS_WINE=( wine wine-mono )

# AUR helpers offered in step 3. Both are in Chaotic-AUR, so they install with
# plain pacman once step 1 has run; only one (or neither) may be chosen.
AUR_HELPERS=( yay paru )

# Developer/diagnostic entries that clutter the application menu. Hiding one
# sets NoDisplay=true in a copy under ~/.local/share/applications, so the
# program stays installed and still works from a terminal, from "Open with",
# and for file associations -- it just stops appearing in the menu. Reversible
# by deleting the override file.
MENU_HIDE=(
    "yad-icon-browser.desktop|Icon Browser"
    "org.gnome.Meld.desktop|Meld"
    "assistant.desktop|Qt Assistant"
    "qdbusviewer.desktop|Qt D-Bus Viewer"
    "linguist.desktop|Qt Linguist"
    "designer.desktop|Qt Widgets Designer"
    "qv4l2.desktop|Qt V4L2 test Utility"
    "qvidcap.desktop|Qt V4L2 video capture utility"
    "uxterm.desktop|UXTerm"
    "xterm.desktop|XTerm"
    "yad-settings.desktop|YAD settings"
)

# The desktop Trash icon is just a Type=Link .desktop file dropped in the
# user's Desktop folder. The ':' is literal and the slash is U+2044 FRACTION
# SLASH, since a real '/' cannot appear in a filename -- this is the name
# Plasma itself writes.
TRASH_DESKTOP_NAME=$'trash:\u2044.desktop'

# The image viewer's desktop file. The Default Applications KCM keys its
# "Image viewer" dropdown off image/png alone, so that entry is what makes
# System Settings show it; the rest are set so every image type opens in it.
KOKO_DESKTOP="org.kde.koko.desktop"
KOKO_IMAGE_TYPES=(
    image/png image/jpeg image/gif image/bmp image/tiff
    image/webp image/x-webp image/avif image/avif-sequence image/heif
    image/svg+xml image/x-eps image/x-icns image/x-ico image/x-psd
    image/x-portable-bitmap image/x-portable-graymap image/x-portable-pixmap
    image/x-xbitmap image/x-xpixmap
)

# Browsers offered in step 4: menu number -> flatpak id
BROWSER_IDS=(
    "one.ablaze.floorp"
    "org.mozilla.firefox"
    "io.github.ungoogled_software.ungoogled_chromium"
    "com.brave.Browser"
)
BROWSER_NAMES=( "Floorp" "Firefox" "Ungoogled Chromium" "Brave" )

# Office suites offered in step 16.
OFFICE_IDS=( "org.libreoffice.LibreOffice" "com.collaboraoffice.Office" )
OFFICE_NAMES=(
    "LibreOffice      -- tried and true"
    "Collabora Office -- newer, closer to the Microsoft Office look"
)

# The one place the step list is defined: number | function | label | name |
# needs-root. Everything else -- the intro screen, --list, --only/--skip and
# the dispatch loop -- is generated from this, so there is no second list to
# keep in sync.
STEPS=(
    "1|setup_chaotic_aur|Chaotic-AUR repository|chaotic|1"
    "2|system_update|System update|update|1"
    "3|install_aur_helper|AUR helper (yay/paru)|aur|1"
    "4|setup_bluetooth|Bluetooth|bluetooth|1"
    "5|setup_bootloader|Default boot kernel|boot|1"
    "6|install_base_packages|Core packages and login manager|packages|1"
    "7|install_browsers|Browsers|browsers|1"
    "8|install_thunderbird|Thunderbird|thunderbird|1"
    "9|deploy_loose_files|Deploy the loose/ config files|files|0"
    "10|install_games|KDE games|games|1"
    "11|configure_dolphin|Dolphin settings|dolphin|0"
    "12|configure_default_image_viewer|Default image viewer|imageviewer|0"
    "13|run_theme_mode|Light or dark mode|theme|1"
    "14|configure_cursor|Cursor theme|cursor|1"
    "15|configure_decorations|Window decorations|decorations|0"
    "16|setup_printing|Printing (CUPS)|printing|1"
    "17|setup_spellcheck|Spell checking|spellcheck|1"
    "18|configure_panels|Panels and system tray|panels|0"
    "19|install_wine|Wine|wine|1"
    "20|install_office|Office suite|office|1"
    "21|tidy_application_menu|Application menu cleanup|menu|0"
    "22|add_trash_to_desktops|Trash icon on every desktop|trash|1"
)

# Steps chosen for this run, as numbers. Filled in by parse_args.
RUN_STEPS=()

step_field() { local e; for e in "${STEPS[@]}"; do [[ "${e%%|*}" == "$1" ]] && { IFS='|' read -r _n _f _l _s _r <<< "$e"; case "$2" in fn) printf '%s\n' "$_f";; label) printf '%s\n' "$_l";; name) printf '%s\n' "$_s";; root) printf '%s\n' "$_r";; esac; return 0; }; done; return 1; }

step_selected() { local n; for n in "${RUN_STEPS[@]}"; do [[ "$n" == "$1" ]] && return 0; done; return 1; }

# Populated as the run goes, so later steps know what actually got installed.
INSTALL_FLOORP=0
INSTALL_THUNDERBIRD=0
INSTALL_GAMES=0

# Set by choose_theme_mode(); everything appearance-related keys off these.
THEME_MODE="dark"
THEME_CHOSEN=0
LOOKANDFEEL="org.kde.breezedark.desktop"
COLORSCHEME="BreezeDark"
ICON_THEME="breeze-dark"
DECORATION_THEME="WillowDark"

# Kept from the reference system so a global-theme apply doesn't drop it.
ACCENT_COLOR="#926EE4"

pac_install() {
    (( $# )) || return 0
    sudo pacman -S --needed --noconfirm "$@"
}

# Remove packages that are installed, leaving the rest alone. Anything still
# required by another package is reported rather than forced out.
pac_remove() {
    local pkg present=()
    for pkg in "$@"; do
        pacman -Qq "$pkg" >/dev/null 2>&1 && present+=( "$pkg" )
    done
    (( ${#present[@]} )) || return 0

    info "Removing: ${present[*]}"
    if sudo pacman -Rns --noconfirm "${present[@]}"; then
        ok "Removed: ${present[*]}"
    else
        fail "Could not remove: ${present[*]} (still required by something?)"
    fi
}

flatpak_install() {
    (( $# )) || return 0
    sudo flatpak install -y --system --noninteractive flathub "$@"
}

# ------------------------------------------------------ argument parsing ----

usage() {
    cat <<'USAGE'
Usage: postinstall.sh [options]

Runs every step by default. To run only part of it:

  --only  <steps>   run just these steps, in script order
  --skip  <steps>   run everything except these
  --list            show the step list and exit
  -h, --help        show this help and exit

<steps> is a comma-separated list of numbers, names, or ranges:

  --only 13             just the light/dark mode step
  --only theme          the same step, by name
  --only 13,14,15       light/dark, cursor and decorations
  --only 13-15          the same, as a range
  --skip 1,2            everything except the repository and the full upgrade
  --skip games,wine     everything except those two

Environment overrides:

  REPO_BRANCH=<branch>        pull the loose/ payload from another branch
  PANEL_HEIGHT=<px>           force a panel height instead of inheriting it
  PANEL_MIN_SCREEN_WIDTH=<px> lower bound for giving a screen a panel

USAGE
}

list_steps() {
    local e n f l nm r
    printf '\n  %-4s %-14s %s\n' "#" "NAME" "STEP"
    printf '  %-4s %-14s %s\n' "---" "-------------" "--------------------------------"
    for e in "${STEPS[@]}"; do
        IFS='|' read -r n f l nm r <<< "$e"
        printf '  %-4s %-14s %s\n' "$n" "$nm" "$l"
    done
    echo
}

# Expand "13", "theme", "5-9" (and comma-separated mixes) into step numbers.
# Echoes the numbers, one per line; returns 1 on anything unrecognized.
expand_step_spec() {
    local spec="$1" token lo hi n e num name rc=0
    IFS=',' read -ra _tokens <<< "$spec"
    for token in "${_tokens[@]}"; do
        token="${token//[[:space:]]/}"
        [[ -z "$token" ]] && continue

        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
            (( lo > hi )) && { n=$lo; lo=$hi; hi=$n; }
            for (( n = lo; n <= hi; n++ )); do
                step_field "$n" fn >/dev/null && printf '%s\n' "$n"
            done
            continue
        fi

        if [[ "$token" =~ ^[0-9]+$ ]]; then
            if step_field "$token" fn >/dev/null; then
                printf '%s\n' "$token"
            else
                err "No such step: $token"; rc=1
            fi
            continue
        fi

        # Otherwise treat it as a name.
        local matched=0
        for e in "${STEPS[@]}"; do
            IFS='|' read -r num _ _ name _ <<< "$e"
            if [[ "${token,,}" == "${name,,}" ]]; then
                printf '%s\n' "$num"; matched=1; break
            fi
        done
        (( matched )) || { err "No such step: $token"; rc=1; }
    done
    return $rc
}

parse_args() {
    local only_spec="" skip_spec="" arg
    while (( $# )); do
        arg="$1"
        case "$arg" in
            -h|--help)  usage; exit 0 ;;
            --list)     list_steps; exit 0 ;;
            --only)     only_spec="${2:-}"; shift 2 || true ;;
            --only=*)   only_spec="${arg#*=}"; shift ;;
            --skip)     skip_spec="${2:-}"; shift 2 || true ;;
            --skip=*)   skip_spec="${arg#*=}"; shift ;;
            *)          err "Unknown option: $arg"; echo; usage; exit 1 ;;
        esac
    done

    if [[ -n "$only_spec" && -n "$skip_spec" ]]; then
        err "--only and --skip cannot be combined."
        exit 1
    fi

    local e n
    RUN_STEPS=()

    if [[ -n "$only_spec" ]]; then
        local wanted=() expanded="" w
        expanded="$(expand_step_spec "$only_spec")" || exit 1
        while read -r w; do
            [[ "$w" =~ ^[0-9]+$ ]] && wanted+=( "$w" )
        done <<< "$expanded"
        (( ${#wanted[@]} )) || { err "--only matched no steps."; exit 1; }
        # Keep script order regardless of how they were typed.
        for e in "${STEPS[@]}"; do
            n="${e%%|*}"
            for w in "${wanted[@]}"; do
                [[ "$n" == "$w" ]] && { RUN_STEPS+=( "$n" ); break; }
            done
        done
    elif [[ -n "$skip_spec" ]]; then
        local dropped=() expanded="" w
        expanded="$(expand_step_spec "$skip_spec")" || exit 1
        while read -r w; do
            [[ "$w" =~ ^[0-9]+$ ]] && dropped+=( "$w" )
        done <<< "$expanded"
        for e in "${STEPS[@]}"; do
            n="${e%%|*}"
            local drop=0 d
            for d in "${dropped[@]}"; do [[ "$n" == "$d" ]] && drop=1; done
            (( drop )) || RUN_STEPS+=( "$n" )
        done
        (( ${#RUN_STEPS[@]} )) || { err "--skip left nothing to run."; exit 1; }
    else
        for e in "${STEPS[@]}"; do RUN_STEPS+=( "${e%%|*}" ); done
    fi
}

# Does anything in this run need root?
run_needs_root() {
    local n
    for n in "${RUN_STEPS[@]}"; do
        [[ "$(step_field "$n" root)" == "1" ]] && return 0
    done
    return 1
}

# --------------------------------------------------------------- intro ------

show_intro() {
    local partial=0
    (( ${#RUN_STEPS[@]} == ${#STEPS[@]} )) || partial=1

    printf '\n%sArch Linux post-install setup%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
    printf '%s\n' "-------------------------------------------------------------"

    if (( partial )); then
        printf '\n  Partial run -- only these steps will run:\n\n'
    else
        printf '\n  This sets up a fresh Arch Linux + KDE Plasma install. It will:\n\n'
    fi

    local n
    for n in "${RUN_STEPS[@]}"; do
        printf '    %3s.  %s\n' "$n" "$(step_field "$n" label)"
    done

    if (( ! partial )); then
        cat <<'INTRO'

  You will be asked about:

    - Which kernel to boot, if more than one is installed
    - An AUR helper: yay, paru, or neither
    - Which browsers you want (Floorp, Firefox, Ungoogled Chromium, Brave)
    - Thunderbird
    - The KDE games
    - Light or dark mode
    - Which office suites you want (LibreOffice, Collabora Office)
    - Whether to hide developer/diagnostic entries from the app menu
INTRO
    fi

    cat <<'INTRO'

  Worth knowing before you start:

    - It adds the Chaotic-AUR repository: this imports and locally signs
      that project's GPG key and installs its keyring from its CDN
    - It makes Plasma Login Manager your display manager, disabling any
      existing one; this takes effect on the next reboot
    - It then runs a full system upgrade (pacman -Syu)
    - It asks for your sudo password up front, and keeps it alive
    - /etc/pacman.conf and /etc/default/grub are backed up before editing
    - Your Plasma panels are deleted and rebuilt, which resets pinned
      launchers back to the defaults
    - Configuration files are downloaded from GitHub, not read from disk

  Only the steps listed above will run. Nothing has been changed yet.

INTRO

    if have_tty; then
        printf '  %sPress Enter to begin, or Ctrl+C to abort.%s ' "$C_BOLD" "$C_RESET"
        read -r </dev/tty
        echo
    else
        warn "No terminal attached; starting without waiting."
    fi
}

# ------------------------------------------------------------ preflight -----

preflight() {
    step "Preflight"

    if [[ $EUID -eq 0 ]]; then
        err "Run this as your normal user, not as root (it uses sudo itself)."
        exit 1
    fi
    if ! command -v pacman >/dev/null; then
        err "pacman not found -- this script is for Arch Linux."
        exit 1
    fi
    for c in curl tar bsdtar sudo; do
        command -v "$c" >/dev/null || { err "Missing required tool: $c"; exit 1; }
    done

    # Every prompt in this script reads from /dev/tty, so there is no point
    # continuing without one.
    if ! have_tty; then
        err "No controlling terminal, but this script is interactive."
        err "Run it from a terminal. 'curl ... | bash' is fine; cron and CI are not."
        exit 1
    fi

    if run_needs_root; then
        info "Caching sudo credentials..."
        sudo -v || { err "sudo failed."; exit 1; }
        # Keep sudo alive for the whole run.
        while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
    else
        info "No selected step needs root; not asking for sudo."
    fi

    ok "Ready."
}

# Always pull the loose/ payload from GitHub rather than trusting the cwd.
fetch_payload() {
    step "Downloading configuration payload"
    WORKDIR="$(mktemp -d)"
    info "Source: $TARBALL_URL"
    if ! curl -fsSL "$TARBALL_URL" -o "$WORKDIR/repo.tar.gz"; then
        err "Could not download the repository payload."
        exit 1
    fi
    tar -xzf "$WORKDIR/repo.tar.gz" -C "$WORKDIR" || { err "Extract failed."; exit 1; }
    LOOSE="$(find "$WORKDIR" -maxdepth 2 -type d -name loose -print -quit)"
    if [[ -z "$LOOSE" ]]; then
        err "No loose/ directory inside the downloaded payload."
        exit 1
    fi
    ok "Payload ready at $LOOSE"
}

# ------------------------------------------------------ Chaotic-AUR ---------

setup_chaotic_aur() {
    step "1. Chaotic-AUR repository"

    if grep -qE '^[[:space:]]*\[chaotic-aur\]' /etc/pacman.conf; then
        ok "[chaotic-aur] is already configured; nothing to do."
        return 0
    fi

    local dir="$WORKDIR/chaotic"
    mkdir -p "$dir"

    info "Fetching the Chaotic-AUR keyring..."
    if ! curl -fsSL -o "$dir/chaotic-keyring.pkg.tar.zst" \
            "$CHAOTIC_CDN/chaotic-keyring.pkg.tar.zst"; then
        fail "Could not download the Chaotic-AUR keyring; skipping the repository."
        return 1
    fi

    # The keyring package ships both the key material (chaotic.gpg) and the
    # list of fingerprints it considers trusted (chaotic-trusted). Reading the
    # fingerprints from there means the script never has to hardcode a key and
    # keeps working if the project rotates or adds one.
    if ! bsdtar -xf "$dir/chaotic-keyring.pkg.tar.zst" -C "$dir" \
            usr/share/pacman/keyrings/ 2>/dev/null; then
        fail "Could not unpack the Chaotic-AUR keyring; skipping the repository."
        return 1
    fi

    local kr="$dir/usr/share/pacman/keyrings"
    local keys=() k
    if [[ -r "$kr/chaotic-trusted" ]]; then
        mapfile -t keys < <(awk -F: '/^[0-9A-Fa-f]{40}:/ {print $1}' "$kr/chaotic-trusted")
    fi
    if (( ${#keys[@]} == 0 )) || [[ ! -r "$kr/chaotic.gpg" ]]; then
        fail "The Chaotic-AUR keyring declared no trusted keys; skipping the repository."
        return 1
    fi

    info "Keys the keyring declares as trusted:"
    for k in "${keys[@]}"; do info "  $k"; done

    info "Importing and locally signing them..."
    if ! sudo pacman-key --add "$kr/chaotic.gpg"; then
        fail "Could not import the Chaotic-AUR keys; skipping the repository."
        return 1
    fi
    for k in "${keys[@]}"; do
        if ! sudo pacman-key --lsign-key "$k"; then
            fail "Could not locally sign Chaotic-AUR key $k; skipping the repository."
            return 1
        fi
    done

    # Installed from the URLs so pacman fetches each .sig and verifies it
    # against the keys just trusted. The keyring package's own install hook
    # then runs a full populate, which also applies revocations.
    info "Installing chaotic-keyring and chaotic-mirrorlist..."
    if ! sudo pacman -U --needed --noconfirm \
            "$CHAOTIC_CDN/chaotic-keyring.pkg.tar.zst" \
            "$CHAOTIC_CDN/chaotic-mirrorlist.pkg.tar.zst"; then
        fail "Could not install the Chaotic-AUR keyring/mirrorlist."
        return 1
    fi

    info "Adding [chaotic-aur] to /etc/pacman.conf..."
    sudo cp /etc/pacman.conf "/etc/pacman.conf.bak.$(date +%Y%m%d%H%M%S)"
    printf '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n' \
        | sudo tee -a /etc/pacman.conf >/dev/null

    if grep -qE '^[[:space:]]*\[chaotic-aur\]' /etc/pacman.conf; then
        ok "[chaotic-aur] enabled."
    else
        fail "Failed to add [chaotic-aur] to /etc/pacman.conf."
    fi
}

# ------------------------------------------------------- system update ------

# Runs after the repositories are set up, so the new ones are picked up here
# instead of needing a second sync. A bare `pacman -Sy` followed by `-S` is a
# partial upgrade, which Arch warns against, so always do the full -Syu.
system_update() {
    step "2. System update"
    info "Synchronizing databases and updating the system..."
    if sudo pacman -Syu --noconfirm; then
        ok "System up to date."
    else
        warn "Full upgrade had trouble; continuing anyway."
    fi
}

# ------------------------------------------------------- 3. AUR helper ------

install_aur_helper() {
    step "3. AUR helper"

    local h
    for h in "${AUR_HELPERS[@]}"; do
        if pacman -Qq "$h" >/dev/null 2>&1 || command -v "$h" >/dev/null 2>&1; then
            ok "$h is already installed; nothing to do."
            return 0
        fi
    done

    echo
    info "  1) yay"
    info "  2) paru"
    echo
    info "Pick one, or leave blank for neither."
    local choice pick=""
    read -r -p "    Selection: " choice </dev/tty

    case "${choice// /}" in
        1|yay)  pick="yay"  ;;
        2|paru) pick="paru" ;;
        "")     info "No AUR helper selected."; return 0 ;;
        *)      warn "Unrecognized choice '$choice' -- skipping."; return 0 ;;
    esac

    # Chaotic-AUR carries both, so this is a normal package install if step 1
    # succeeded.
    if pacman -Si "$pick" >/dev/null 2>&1; then
        if pac_install "$pick"; then
            ok "$pick installed."
        else
            fail "Could not install $pick."
        fi
        return 0
    fi

    # Otherwise fall back to building it from the AUR by hand.
    warn "$pick is not in any configured repository; building it from the AUR."
    if ! pac_install git base-devel; then
        fail "Could not install git/base-devel; skipping $pick."
        return 1
    fi
    local src="$WORKDIR/$pick"
    if git clone --depth 1 "https://aur.archlinux.org/${pick}.git" "$src" >/dev/null 2>&1 \
       && ( cd "$src" && makepkg -si --noconfirm >/dev/null 2>&1 ); then
        ok "$pick built and installed."
    else
        fail "Could not build $pick from the AUR."
    fi
}

# -------------------------------------------------- 4. bluetooth ------------

setup_bluetooth() {
    step "4. Bluetooth"
    pac_install bluez bluez-utils || fail "bluez install failed"
    if sudo systemctl enable --now bluetooth.service; then
        ok "bluetooth.service enabled and started."
    else
        fail "Could not enable/start bluetooth.service"
    fi
}

# ----------------------------------------- 5. bootloader default ------------

# Print "<pkgver> <image-path> <pkgbase> <kernel-release>" for each installed
# kernel. /boot/vmlinuz-* is copied into place by a hook and is not owned by any
# package, so the authoritative list is the pkgbase marker each kernel package
# drops in /usr/lib/modules/<release>/.
list_kernels() {
    local d pkgbase ver kver img cand
    for d in /usr/lib/modules/*/; do
        [[ -f "$d/pkgbase" ]] || continue
        pkgbase="$(<"$d/pkgbase")"
        kver="$(basename "$d")"
        ver="$(pacman -Q "$pkgbase" 2>/dev/null | awk '{print $2}')"
        [[ -n "$ver" ]] || ver="$kver"

        # Prefer the copy the bootloader actually points at.
        img=""
        for cand in "/boot/vmlinuz-$pkgbase" "/boot/vmlinuz-$kver" "${d%/}/vmlinuz"; do
            [[ -f "$cand" ]] && { img="$cand"; break; }
        done
        [[ -n "$img" ]] && printf '%s %s %s %s\n' "$ver" "$img" "$pkgbase" "$kver"
    done
}

# Walk grub.cfg and emit "<positional path>|<id path>|<kernel image>" for every
# entry, covering both the numeric form GRUB_DEFAULT accepts (0, 1>2) and the
# more robust menuentry-id form.
grub_entry_map() {
    sudo awk '
        function id_of(line,   n, a) {
            n = index(line, "menuentry_id_option")
            if (n == 0) return ""
            a = substr(line, n)
            n = index(a, "\047"); if (n == 0) return ""
            a = substr(a, n + 1)
            n = index(a, "\047"); if (n == 0) return ""
            return substr(a, 1, n - 1)
        }
        BEGIN { top = -1; subidx = -1; sub_id = "" }
        /^[[:space:]]*submenu[[:space:]]/ { top++; sub_id = id_of($0); subidx = -1; next }
        /^[[:space:]]+menuentry[[:space:]]/ {
            if (sub_id != "") {
                subidx++
                cur_pos = top ">" subidx
                cur_id  = sub_id ">" id_of($0)
            }
            next
        }
        /^menuentry[[:space:]]/ { top++; cur_pos = top; cur_id = id_of($0); next }
        /^}/ { sub_id = ""; next }
        /^[[:space:]]*linux(16|efi)?[[:space:]]/ {
            if (cur_id != "") { print cur_pos "|" cur_id "|" $2; cur_id = "" }
        }
    ' /boot/grub/grub.cfg
}

# What does the current GRUB_DEFAULT actually boot? Echoes the kernel image.
grub_current_kernel() {
    local default pos id kernel
    default="$(awk -F= '/^[[:space:]]*GRUB_DEFAULT=/ {
                   v = $2; gsub(/^[\047"]|[\047"]$/, "", v); print v; exit }' /etc/default/grub)"
    [[ -n "$default" ]] || default="0"

    if [[ "$default" == "saved" ]]; then
        default="$(sudo awk -F= '/^saved_entry=/ {print $2; exit}' /boot/grub/grubenv 2>/dev/null)"
        [[ -n "$default" ]] || return 1
    fi

    while IFS='|' read -r pos id kernel; do
        if [[ "$default" == "$pos" || "$default" == "$id" ]]; then
            printf '%s\n' "$kernel"
            return 0
        fi
    done < <(grub_entry_map)
    return 1
}

# Count the directives that draw a background or theme, so a regeneration that
# silently drops them can be caught and rolled back.
grub_decor_count() {
    sudo grep -cE '^[[:space:]]*(background_image|set[[:space:]]+theme=)' \
        /boot/grub/grub.cfg 2>/dev/null || echo 0
}

setup_grub_default() {
    local target_img="$1" target_base entry pos id kernel target="" current
    target_base="$(basename "$target_img")"

    if [[ ! -r /boot/grub/grub.cfg ]] && ! sudo test -r /boot/grub/grub.cfg; then
        fail "/boot/grub/grub.cfg is not readable; leaving GRUB alone."
        return 1
    fi

    # Nothing to do if the existing default already boots the newest kernel.
    # This is the common case on a system that is already set up correctly,
    # and it means the script does not touch GRUB at all.
    if current="$(grub_current_kernel)" && [[ "$(basename "$current")" == "$target_base" ]]; then
        ok "GRUB already boots $target_base by default; leaving it untouched."
        return 0
    fi

    # Read the menu as it stands -- no pre-emptive regeneration.
    while IFS='|' read -r pos id kernel; do
        [[ "$(basename "$kernel")" == "$target_base" ]] || continue
        if [[ "$id" != *">"* ]]; then target="$id"; break; fi
        [[ -z "$target" ]] && target="$id"
    done < <(grub_entry_map)

    if [[ -z "$target" ]]; then
        fail "No GRUB entry for $target_base in the current menu; leaving GRUB alone."
        return 1
    fi

    local decor_before decor_after stamp
    decor_before="$(grub_decor_count)"
    stamp="$(date +%Y%m%d%H%M%S)"

    info "Setting GRUB_DEFAULT to '$target' (only that line is changed)."
    sudo cp /etc/default/grub "/etc/default/grub.bak.$stamp"
    sudo cp /boot/grub/grub.cfg "/boot/grub/grub.cfg.bak.$stamp"

    if sudo grep -qE '^[[:space:]]*GRUB_DEFAULT=' /etc/default/grub; then
        sudo sed -i "s|^[[:space:]]*GRUB_DEFAULT=.*|GRUB_DEFAULT='${target}'|" /etc/default/grub
    else
        printf "GRUB_DEFAULT='%s'\n" "$target" | sudo tee -a /etc/default/grub >/dev/null
    fi

    # GRUB_DEFAULT is only read when the menu is generated, so one regeneration
    # is unavoidable. Everything else in /etc/default/grub is left as it was.
    if ! sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1; then
        fail "grub-mkconfig failed; restoring the previous grub.cfg."
        sudo cp "/boot/grub/grub.cfg.bak.$stamp" /boot/grub/grub.cfg
        sudo cp "/etc/default/grub.bak.$stamp" /etc/default/grub
        return 1
    fi

    decor_after="$(grub_decor_count)"
    if (( decor_before > 0 && decor_after == 0 )); then
        fail "Regenerating grub.cfg dropped the background/theme; restoring the backup."
        sudo cp "/boot/grub/grub.cfg.bak.$stamp" /boot/grub/grub.cfg
        sudo cp "/etc/default/grub.bak.$stamp" /etc/default/grub
        return 1
    fi

    ok "GRUB now boots $target_base by default (background/theme preserved)."
}

setup_sdboot_default() {
    local target_img="$1" target_pkgbase="$2" target_kver="$3"
    local target_base esp entry line best=""
    target_base="$(basename "$target_img")"
    esp="$(bootctl --print-esp-path 2>/dev/null)" || esp="/boot"
    [[ -d "$esp/loader/entries" ]] || esp="/boot"

    # A loader entry's linux= line can be written several ways depending on
    # whether mkinitcpio or kernel-install generated it:
    #   linux /vmlinuz-linux
    #   linux /<machine-id>/<kernel-release>/linux
    # so accept a match on the image name, the pkgbase, or the kernel release.
    for entry in "$esp"/loader/entries/*.conf; do
        [[ -f "$entry" ]] || continue
        line="$(sudo grep -E '^[[:space:]]*linux[[:space:]]' "$entry" 2>/dev/null)"
        [[ -n "$line" ]] || continue
        if [[ "$line" == *"$target_base"* || "$line" == *"/$target_pkgbase"* \
              || "$line" == *"$target_kver"* ]]; then
            best="$(basename "$entry")"
            # Prefer a normal entry over a fallback one.
            [[ "$best" == *fallback* ]] || break
        fi
    done

    if [[ -z "$best" ]]; then
        fail "No systemd-boot entry references $target_base; leaving loader.conf alone."
        return 1
    fi

    sudo cp "$esp/loader/loader.conf" "$esp/loader/loader.conf.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    if sudo grep -qE '^[[:space:]]*default[[:space:]]' "$esp/loader/loader.conf" 2>/dev/null; then
        sudo sed -i "s|^[[:space:]]*default[[:space:]].*|default ${best}|" "$esp/loader/loader.conf"
    else
        printf 'default %s\n' "$best" | sudo tee -a "$esp/loader/loader.conf" >/dev/null
    fi
    ok "systemd-boot now boots $best by default."
}

setup_bootloader() {
    step "5. Default boot kernel"

    local vers=() imgs=() bases=() kvers=() v i b k
    while read -r v i b k; do
        vers+=( "$v" ); imgs+=( "$i" ); bases+=( "$b" ); kvers+=( "$k" )
    done < <(list_kernels)

    local count=${#vers[@]}
    if (( count < 2 )); then
        info "Only $count kernel installed -- nothing to choose between. Skipping."
        return 0
    fi

    # Mark the newest so the choice is obvious; pacman decides what "newest" is.
    local newest=0 n
    for (( n = 1; n < count; n++ )); do
        [[ "$(vercmp "${vers[$n]}" "${vers[$newest]}")" -gt 0 ]] && newest=$n
    done

    echo
    info "More than one kernel is installed:"
    echo
    local width=0
    for (( n = 0; n < count; n++ )); do
        (( ${#bases[$n]} > width )) && width=${#bases[$n]}
    done
    for (( n = 0; n < count; n++ )); do
        printf '      %d) %-*s  %s%s\n' "$((n + 1))" "$width" "${bases[$n]}" \
            "${vers[$n]}" "$( (( n == newest )) && printf '   (newest)' )"
    done
    echo
    info "Accepts a number, a kernel name, \"latest\" or \"lts\"."

    local choice pick=$newest
    read -r -p "    Which should the bootloader start by default? [$((newest + 1))] " \
        choice </dev/tty
    choice="${choice//[[:space:]]/}"

    if [[ -n "$choice" ]]; then
        local resolved=-1
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            resolved=$(( choice - 1 ))
        elif [[ "${choice,,}" == "latest" || "${choice,,}" == "newest" ]]; then
            resolved=$newest
        else
            for (( n = 0; n < count; n++ )); do
                # "lts" matches linux-lts, "zen" matches linux-zen, and so on.
                if [[ "${bases[$n],,}" == "${choice,,}" \
                   || "${bases[$n],,}" == "linux-${choice,,}" ]]; then
                    resolved=$n; break
                fi
            done
        fi

        if (( resolved < 0 )); then
            warn "Unrecognized choice '$choice' -- using the newest kernel."
        else
            pick=$resolved
        fi
    fi

    info "Default boot kernel: ${bases[$pick]} (${vers[$pick]})"

    if [[ -d /boot/grub ]] && command -v grub-mkconfig >/dev/null; then
        setup_grub_default "${imgs[$pick]}"
    elif command -v bootctl >/dev/null && bootctl is-installed >/dev/null 2>&1; then
        setup_sdboot_default "${imgs[$pick]}" "${bases[$pick]}" "${kvers[$pick]}"
    else
        warn "Neither GRUB nor systemd-boot detected. Skipping."
    fi
}

# ---------------------------------------------- 6. base packages ------------

install_base_packages() {
    step "6. Core packages (KDE, Plasma, Discover, Flatpak, portals)"
    info "Installing ${#PKGS_BASE[@]} packages -- this takes a while."
    if pac_install "${PKGS_BASE[@]}"; then
        ok "Core packages installed."
    else
        fail "Some core packages failed to install."
    fi

    pac_remove "${PKGS_REMOVE[@]}"

    setup_login_manager

    # Flathub must exist before any of the flatpak steps below.
    if command -v flatpak >/dev/null; then
        sudo flatpak remote-add --if-not-exists --system \
            flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 \
            && ok "Flathub remote configured." \
            || fail "Could not add the Flathub remote."
    fi
}

# Make Plasma Login Manager the display manager. Only one unit can hold the
# display-manager.service alias, so an existing one has to be disabled first.
# If enabling fails the previous manager is put back, so the machine is never
# left without a way to log in.
setup_login_manager() {
    if ! pacman -Qq plasma-login-manager >/dev/null 2>&1; then
        fail "plasma-login-manager is not installed; leaving the display manager alone."
        return 1
    fi

    # On a fresh KDE install there is usually no display manager at all, so the
    # alias simply won't exist and there is nothing to disable. Three cases:
    # no alias, an alias pointing at a live unit, and a stale alias left behind
    # by a removed one (which would otherwise make `systemctl enable` fail).
    local dm_alias="/etc/systemd/system/display-manager.service"
    local current=""

    if [[ -L "$dm_alias" && ! -e "$dm_alias" ]]; then
        info "Clearing a stale display-manager.service link..."
        sudo rm -f "$dm_alias" || warn "Could not remove the stale link."
    elif [[ -e "$dm_alias" ]]; then
        current="$(basename "$(readlink -f "$dm_alias" 2>/dev/null)" 2>/dev/null)"
    fi

    if [[ "$current" == "plasmalogin.service" ]]; then
        ok "Plasma Login Manager is already the display manager."
        return 0
    fi

    if [[ -n "$current" ]]; then
        info "Disabling the current display manager ($current)..."
        sudo systemctl disable "$current" >/dev/null 2>&1 \
            || warn "Could not disable $current; enabling may fail."
    else
        info "No display manager is currently enabled."
    fi

    # Deliberately not --now: switching the display manager mid-session would
    # kill the running desktop. It takes effect on the next reboot.
    if sudo systemctl enable plasmalogin.service >/dev/null 2>&1; then
        ok "Plasma Login Manager enabled as the display manager."
        info "Takes effect on the next reboot."
    else
        fail "Could not enable plasmalogin.service."
        if [[ -n "$current" ]] && sudo systemctl enable "$current" >/dev/null 2>&1; then
            warn "Put $current back so you still have a login screen."
        fi
    fi
}

# ------------------------------------------------ 4/5. browsers + Floorp ----

install_browsers() {
    step "7. Browsers (Flatpak)"
    local chosen=() n id

    ask_multi "${BROWSER_NAMES[@]}"
    for n in "${SELECTED[@]}"; do
        id="${BROWSER_IDS[$((n - 1))]}"
        chosen+=( "$id" )
        [[ "$id" == "one.ablaze.floorp" ]] && INSTALL_FLOORP=1
    done

    if (( ${#chosen[@]} == 0 )); then
        info "No browsers selected."
        return 0
    fi
    info "Installing: ${chosen[*]}"
    flatpak_install "${chosen[@]}" && ok "Browsers installed." \
        || fail "One or more browser flatpaks failed to install."

    if (( INSTALL_FLOORP )); then
        # Step 5: Floorp needs read/write access to $HOME.
        if sudo flatpak override --system --filesystem=home one.ablaze.floorp; then
            ok "Floorp granted read/write access to your home directory."
        else
            fail "Could not set the Floorp home-directory permission."
        fi
    fi
}

# ------------------------------------------------ 8. Thunderbird ------------

install_thunderbird() {
    step "8. Thunderbird"
    if ask_yn "Install Thunderbird (Flatpak)?"; then
        if flatpak_install org.mozilla.thunderbird; then
            INSTALL_THUNDERBIRD=1
            ok "Thunderbird installed."
        else
            fail "Thunderbird install failed."
        fi
    else
        info "Skipped."
    fi
}

# --------------------------------- 9. deploy loose/ config files ------------

# Echo the default profile directory under a Firefox-family root, creating
# nothing. Prefers the install's default-release profile, then Default=1.
find_moz_profile() {
    local root="$1" ini="$1/profiles.ini" path
    [[ -f "$ini" ]] || return 1

    # The [InstallXXXX] section's Default= is the profile the app actually opens.
    path="$(awk -F= '
        /^\[Install/ { ins=1; next }
        /^\[/        { ins=0 }
        ins && $1=="Default" { print $2; exit }
    ' "$ini")"

    if [[ -z "$path" ]]; then
        path="$(awk -F= '
            /^\[Profile/ { p=""; d=0 }
            $1=="Path"    { p=$2 }
            $1=="Default" && $2=="1" { d=1 }
            /^$/ { if (d && p) { print p; exit } }
            END  { if (d && p) print p }
        ' "$ini")"
    fi
    [[ -z "$path" ]] && return 1
    [[ "$path" = /* ]] || path="$root/$path"
    [[ -d "$path" ]] || return 1
    printf '%s\n' "$path"
}

# Find the newest *.default-release (or any profile dir) as a fallback.
guess_moz_profile() {
    local root="$1" d
    for d in "$root"/*.default-release "$root"/*.default "$root"/*; do
        [[ -d "$d" && -f "$d/prefs.js" ]] && { printf '%s\n' "$d"; return 0; }
    done
    for d in "$root"/*.default-release "$root"/*.default; do
        [[ -d "$d" ]] && { printf '%s\n' "$d"; return 0; }
    done
    return 1
}

# Drop userChrome.css into a profile and turn on legacy stylesheet support.
deploy_userchrome() {
    local label="$1" src="$2" root="$3" profile
    [[ -f "$src" ]] || { warn "$label: no userChrome.css in the payload."; return 1; }
    [[ -d "$root" ]] || { info "$label: not installed (no $root) -- skipped."; return 1; }

    profile="$(find_moz_profile "$root")" || profile="$(guess_moz_profile "$root")" || {
        warn "$label: could not identify a profile directory. Launch it once, then re-run."
        return 1
    }

    mkdir -p "$profile/chrome"
    cp "$src" "$profile/chrome/userChrome.css"

    # userChrome.css is ignored unless this pref is on (see the documentation
    # file in loose/Application Configurations/).
    local userjs="$profile/user.js"
    if ! grep -q 'toolkit.legacyUserProfileCustomizations.stylesheets' "$userjs" 2>/dev/null; then
        printf 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);\n' >> "$userjs"
    fi
    ok "$label: userChrome.css -> ${profile/#$HOME/\~}/chrome/"
}

deploy_loose_files() {
    step "9. Deploying the loose/ configuration files"
    local cfg="$LOOSE/Application Configurations"

    # --- Floorp (Flatpak) ---
    deploy_userchrome "Floorp" "$cfg/Floorp/chrome/userChrome.css" \
        "$HOME/.var/app/one.ablaze.floorp/.floorp"

    # --- Firefox (Flatpak first, then a native install) ---
    if [[ -d "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" ]]; then
        deploy_userchrome "Firefox (Flatpak)" "$cfg/Firefox/chrome/userChrome.css" \
            "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
    else
        deploy_userchrome "Firefox" "$cfg/Firefox/chrome/userChrome.css" \
            "$HOME/.mozilla/firefox"
    fi

    # --- Thunderbird ---
    local tb_root="" r
    for r in "$HOME/.var/app/org.mozilla.thunderbird/.thunderbird" \
             "$HOME/.var/app/org.mozilla.Thunderbird/.thunderbird" \
             "$HOME/.thunderbird"; do
        [[ -d "$r" ]] && { tb_root="$r"; break; }
    done
    if [[ -n "$tb_root" ]]; then
        deploy_userchrome "Thunderbird" "$cfg/Thunderbird/chrome/userChrome.css" "$tb_root"
    else
        info "Thunderbird: not installed / never launched -- skipped."
    fi

    # --- Window decoration themes (step 11 applies whichever was chosen) ---
    # Both variants are installed so switching light/dark later needs no re-run.
    local deco
    for deco in WillowDark WillowLight; do
        if [[ -d "$LOOSE/Window Decorations/$deco" ]]; then
            mkdir -p "$HOME/.local/share/aurorae/themes"
            cp -r "$LOOSE/Window Decorations/$deco" "$HOME/.local/share/aurorae/themes/"
            ok "$deco -> ~/.local/share/aurorae/themes/$deco"
        fi
    done

    # --- Reference docs, kept out of any profile on purpose ---
    local doc="$cfg/documentation (DO NOT PUT IN FIREFOX PROFILE).txt"
    if [[ -f "$doc" ]]; then
        mkdir -p "$HOME/Documents/Arch Postinstall"
        cp "$doc" "$HOME/Documents/Arch Postinstall/"
        ok "Reference notes -> ~/Documents/Arch Postinstall/"
    fi

    if (( INSTALL_FLOORP || INSTALL_THUNDERBIRD )); then
        info "Note: a freshly installed Flatpak has no profile until you launch it once."
        info "      If something was skipped above, launch the app and re-run this script."
    fi
}

# ----------------------------------------------------- 10. games ------------

install_games() {
    step "10. KDE games"
    if ask_yn "Install the KDE games (${PKGS_GAMES[*]})?"; then
        if pac_install "${PKGS_GAMES[@]}"; then
            INSTALL_GAMES=1
            ok "Games installed."
        else
            fail "Game packages failed to install."
        fi
    else
        info "Skipped."
    fi
}

# --------------------------------------------------- 11. dolphin ------------

configure_dolphin() {
    step "11. Dolphin settings"
    local f="$HOME/.config/dolphinrc"

    kw "$f" DetailsMode IconSize 32
    kw "$f" DetailsMode PreviewSize 32
    kw "$f" General DynamicView true
    kw "$f" General GlobalViewProps false
    kw "$f" General RememberOpenedTabs false
    kw "$f" General ShowStatusBar FullWidth
    kw "$f" General ShowZoomSlider true
    kw "$f" "KFileDialog Settings" "Places Icons Auto-resize" false
    kw "$f" "KFileDialog Settings" "Places Icons Static Size" 32
    kw "$f" PlacesPanel IconSize 32
    kw "$f" Search SearchTool Baloo

    # Dolphin treats "GeneralSettings::version() < 200" as a first run and force
    # hides the menubar, which overrides the MenuBar setting below no matter what
    # it says. Claiming the current config version stops that, and on a fresh
    # config there is nothing for the skipped migrations to do anyway.
    kw "$f" General Version 202
    kw "$f" General ViewPropsTimestamp "$(date '+%Y,%-m,%-d,%-H,%-M,%-S.000')"

    # Show the menubar rather than the hamburger button.
    kw "$f" MainWindow MenuBar Enabled
    kw "$f" PreviewSettings Plugins \
        "ffmpegthumbnailer,appimagethumbnail,audiothumbnail,blenderthumbnail,comicbookthumbnail,cursorthumbnail,djvuthumbnail,ebookthumbnail,exrthumbnail,directorythumbnail,fontthumbnail,imagethumbnail,jpegthumbnail,kraorathumbnail,windowsexethumbnail,windowsimagethumbnail,mobithumbnail,opendocumentthumbnail,gsthumbnail,rawthumbnail,svgthumbnail,ffmpegthumbs,gdk-pixbuf-thumbnailer,gsf-office"

    ok "dolphinrc written."

    # The toolbar layout and menu structure live in Dolphin's KXMLGUI file,
    # not in dolphinrc. KF6 still uses the "kxmlgui5" directory name.
    local ui_src="$LOOSE/Application Configurations/Dolphin/dolphinui.rc"
    local ui_dest="$HOME/.local/share/kxmlgui5/dolphin"

    if [[ -z "${LOOSE:-}" || ! -f "$ui_src" ]]; then
        warn "dolphinui.rc not in the payload; toolbar left at its defaults."
        return 0
    fi

    mkdir -p "$ui_dest"
    if cp -f "$ui_src" "$ui_dest/dolphinui.rc"; then
        ok "Dolphin toolbar and menu layout applied."
    else
        fail "Could not write $ui_dest/dolphinui.rc."
    fi
}

# ------------------------------------------- 12. default image viewer -------

configure_default_image_viewer() {
    # koko is the package name; its menu name has changed before, so take it
    # from the .desktop file rather than assuming.
    local app
    app="$(desktop_app_name "$KOKO_DESKTOP" "koko")"

    step "12. Default image viewer ($app)"

    if ! pacman -Qq koko >/dev/null 2>&1; then
        fail "koko is not installed; leaving the image associations alone."
        return 1
    fi

    local f="$HOME/.config/mimeapps.list" t
    mkdir -p "$(dirname "$f")"

    for t in "${KOKO_IMAGE_TYPES[@]}"; do
        kwriteconfig6 --file "$f" --group "Default Applications" --key "$t" "$KOKO_DESKTOP;"
    done

    # Matches what the KCM itself writes, so System Settings ->
    # Default Applications -> Multimedia shows this app as the image viewer.
    kwriteconfig6 --file "$f" --group "Added Associations" --key "image/png" "$KOKO_DESKTOP;"

    ok "$app set as the default image viewer."
}

# ------------------------------------------- light / dark mode + appearance --

choose_theme_mode() {
    step "13. Light or dark mode"
    echo
    info "  1) Dark  -- Breeze Dark, dark icons, Willow Dark window decorations"
    info "  2) Light -- Breeze Light, light icons, Willow Light window decorations"
    echo
    local choice
    read -r -p "    Selection [1]: " choice </dev/tty
    choice="${choice:-1}"

    case "$choice" in
        2|light|Light|LIGHT)
            THEME_MODE="light"
            LOOKANDFEEL="org.kde.breeze.desktop"
            COLORSCHEME="BreezeLight"
            ICON_THEME="breeze"
            DECORATION_THEME="WillowLight"
            ;;
        *)
            THEME_MODE="dark"
            LOOKANDFEEL="org.kde.breezedark.desktop"
            COLORSCHEME="BreezeDark"
            ICON_THEME="breeze-dark"
            DECORATION_THEME="WillowDark"
            ;;
    esac
    THEME_CHOSEN=1
    ok "Using ${THEME_MODE} mode."
}

# Step 13 is the prompt plus the apply, as one unit.
run_theme_mode() {
    choose_theme_mode
    apply_theme_mode
}

apply_theme_mode() {
    info "Applying the ${THEME_MODE} theme..."

    # -a applies appearance only; --resetLayout (which would wipe the panels)
    # is deliberately not passed.
    if command -v plasma-apply-lookandfeel >/dev/null \
       && plasma-apply-lookandfeel -a "$LOOKANDFEEL" >/dev/null 2>&1; then
        ok "Global theme set to $LOOKANDFEEL."
    else
        # No Plasma session (or the tool is missing) -- write the config directly.
        kw "$HOME/.config/kdeglobals" KDE LookAndFeelPackage "$LOOKANDFEEL"
        warn "Could not apply the global theme live; wrote it to kdeglobals instead."
    fi

    if command -v plasma-apply-colorscheme >/dev/null \
       && plasma-apply-colorscheme "$COLORSCHEME" -a "$ACCENT_COLOR" >/dev/null 2>&1; then
        ok "Color scheme set to $COLORSCHEME (accent $ACCENT_COLOR)."
    else
        kw "$HOME/.config/kdeglobals" General ColorScheme "$COLORSCHEME"
        kw "$HOME/.config/kdeglobals" General AccentColor "146,110,228"
        warn "Could not apply the color scheme live; wrote it to kdeglobals instead."
    fi

    kw "$HOME/.config/kdeglobals" Icons Theme "$ICON_THEME"
    ok "Icon theme set to $ICON_THEME."

    apply_login_manager_theme
}

# The login greeter runs as its own system user and reads its own kdeglobals
# rather than yours, which is why the login screen otherwise stays light when
# you pick dark. Plasma Login keeps its home at /var/lib/plasmalogin.
PLASMALOGIN_USER="plasmalogin"
PLASMALOGIN_HOME="/var/lib/plasmalogin"

apply_login_manager_theme() {
    if ! id -u "$PLASMALOGIN_USER" >/dev/null 2>&1; then
        warn "No '$PLASMALOGIN_USER' user -- Plasma Login Manager isn't installed."
        warn "The login screen keeps its own theme. Install plasma-login-manager,"
        warn "then re-run this script to theme it."
        return 1
    fi

    if ! sudo install -d -o "$PLASMALOGIN_USER" -g "$PLASMALOGIN_USER" -m 0750 \
            "$PLASMALOGIN_HOME/.config"; then
        fail "Could not create $PLASMALOGIN_HOME/.config."
        return 1
    fi

    # kwriteconfig6 would write into the greeter's home as root, so build the
    # file here and hand it over with the right ownership instead.
    local tmp="$WORKDIR/plasmalogin-kdeglobals"
    cat > "$tmp" <<EOF
[General]
ColorScheme=$COLORSCHEME

[Icons]
Theme=$ICON_THEME

[KDE]
LookAndFeelPackage=$LOOKANDFEEL
EOF

    if sudo install -o "$PLASMALOGIN_USER" -g "$PLASMALOGIN_USER" -m 0644 \
            "$tmp" "$PLASMALOGIN_HOME/.config/kdeglobals"; then
        ok "Login screen set to $COLORSCHEME."
    else
        fail "Could not theme the login screen."
    fi
}

# ---------------------------------------------------- 14. cursor ------------

configure_cursor() {
    step "14. Cursor theme (Breeze Light)"
    pac_install breeze-cursors >/dev/null 2>&1

    if [[ ! -d /usr/share/icons/Breeze_Light && ! -d "$HOME/.local/share/icons/Breeze_Light" ]]; then
        fail "Breeze_Light cursor theme not found on disk."
        return 1
    fi

    kw "$HOME/.config/kcminputrc" Mouse cursorTheme Breeze_Light
    # Also point the Xcursor default at it, for apps outside Plasma.
    mkdir -p "$HOME/.icons/default"
    printf '[Icon Theme]\nInherits=Breeze_Light\n' > "$HOME/.icons/default/index.theme"

    if command -v plasma-apply-cursortheme >/dev/null; then
        plasma-apply-cursortheme Breeze_Light >/dev/null 2>&1 \
            && ok "Cursor theme applied live." \
            || ok "Cursor theme set (takes effect after logout)."
    else
        ok "Cursor theme set (takes effect after logout)."
    fi
}

# ---------------------------------------- 15. window decorations ------------

configure_decorations() {
    # Running this on its own (--only decorations) means no light/dark choice
    # was made, so take it from the look-and-feel already in use.
    if (( ! THEME_CHOSEN )); then
        local laf
        laf="$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)"
        if [[ -n "$laf" && "$laf" != *dark* ]]; then
            DECORATION_THEME="WillowLight"
        else
            DECORATION_THEME="WillowDark"
        fi
    fi

    step "15. Window decorations ($DECORATION_THEME)"
    local theme_dir="$HOME/.local/share/aurorae/themes/$DECORATION_THEME"

    if [[ ! -d "$theme_dir" ]]; then
        fail "$DECORATION_THEME aurorae theme is missing; skipping."
        return 1
    fi

    local f="$HOME/.config/kwinrc"
    kw "$f" org.kde.kdecoration2 library org.kde.kwin.aurorae.v2
    kw "$f" org.kde.kdecoration2 theme "__aurorae__svg__$DECORATION_THEME"
    kw "$f" org.kde.kdecoration2 ButtonsOnLeft "M"

    # Ask KWin to pick it up now if a session is running.
    qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 \
        || qdbus org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true

    ok "$DECORATION_THEME set as the window decoration."
}

# -------------------------------------------------- 16. printing ------------

setup_printing() {
    step "16. Printing (CUPS)"
    if pac_install "${PKGS_PRINT[@]}"; then
        ok "Print packages installed."
    else
        fail "Some print packages failed to install."
    fi

    sudo systemctl enable --now cups.socket >/dev/null 2>&1 \
        && ok "cups.socket enabled." || fail "Could not enable cups.socket"
    sudo systemctl enable cups.service >/dev/null 2>&1 \
        && ok "cups.service enabled." || fail "Could not enable cups.service"

    # Needed for automatic discovery of network printers.
    if pacman -Qq avahi >/dev/null 2>&1 || pac_install avahi >/dev/null 2>&1; then
        sudo systemctl enable --now avahi-daemon.service >/dev/null 2>&1 \
            && ok "avahi-daemon enabled (network printer discovery)."
    fi

    # cups-browsed is installed but left disabled, matching the reference system.
    info "cups-browsed installed but left disabled."
    info "  Enable it only if you need legacy CUPS broadcast discovery:"
    info "  sudo systemctl enable --now cups-browsed.service"
}

# ---------------------------------------------- 17. spellchecker ------------

setup_spellcheck() {
    step "17. Spell checking (Sonnet + Hunspell)"
    if pac_install "${PKGS_SPELL[@]}"; then
        ok "Spell-check packages installed."
    else
        fail "Spell-check packages failed to install."
    fi

    local f="$HOME/.config/KDE/Sonnet.conf"
    mkdir -p "$(dirname "$f")"
    kw "$f" General autodetectLanguage true
    kw "$f" General backgroundCheckerEnabled true
    kw "$f" General checkUppercase true
    kw "$f" General checkerEnabledByDefault false
    kw "$f" General defaultLanguage en_US
    kw "$f" General preferredLanguages "en_US, en_US-large"
    kw "$f" General skipRunTogether true
    kw "$f" General ignore_en_US \
        "Amarok, KAddressBook, KDevelop, KHTML, KIO, KJS, KMail, KMix, KOrganizer, Konqueror, Kontact, Okular, Qt, Sonnet"

    ok "Sonnet configured for en_US (Hunspell backend)."
}

# ------------------------------------------ 18. panels + systray ------------

configure_panels() {
    step "18. Panels and system tray on every monitor"

    local qdbus_cmd=""
    for c in qdbus6 qdbus qdbus-qt6; do command -v "$c" >/dev/null && { qdbus_cmd="$c"; break; }; done
    if [[ -z "$qdbus_cmd" ]] || ! "$qdbus_cmd" org.kde.plasmashell >/dev/null 2>&1; then
        warn "Plasma isn't running (or qdbus is unavailable)."
        warn "Log into your Plasma session and re-run this script to set up the panels."
        return 1
    fi

    # Tray items are taken from the main monitor's panel on the reference
    # system, minus anything whose providing app this script doesn't install:
    # firewall-applet, polychromatic-tray-applet and Proton Mail Bridge.
    local extra_items="org.kde.plasma.keyboardindicator,org.kde.plasma.devicenotifier,org.kde.kdeconnect,org.kde.plasma.clipboard,org.kde.plasma.networkmanagement,org.kde.plasma.mediacontroller,org.kde.plasma.manage-inputmethod,org.kde.plasma.bluetooth,org.kde.plasma.printmanager,org.kde.plasma.notifications,org.kde.kscreen,org.kde.plasma.cameraindicator,org.kde.plasma.keyboardlayout,org.kde.plasma.volume,org.kde.plasma.vault,org.kde.plasma.brightness,org.kde.plasma.kclock_1x2,org.kde.plasma.weather,org.kde.plasma.battery"

    local hidden_items="org.kde.plasma.brightness,org.kde.plasma.keyboardlayout,org.kde.plasma.clipboard,org.kde.plasma.weather,org.kde.plasma.battery"
    (( INSTALL_THUNDERBIRD )) && hidden_items="${hidden_items},Thunderbird"

    # A full taskbar is unusable on a tiny secondary output (a 640x480 capture
    # device, say), so only build panels on screens at least this wide.
    local min_width="${PANEL_MIN_SCREEN_WIDTH:-1024}"

    # A brand new Panel object is 30px, which is thinner than the panel Plasma
    # itself creates. Reuse the height of whatever panel is already there so
    # rebuilding doesn't silently shrink it; PANEL_HEIGHT overrides, and 30 is
    # only the last resort when there is no existing panel to copy.
    local forced_height="${PANEL_HEIGHT:-0}"

    local js
    js=$(cat <<JS_EOF
var extraItems   = "${extra_items}";
var hiddenItems  = "${hidden_items}";
var minWidth     = ${min_width};
var forcedHeight = ${forced_height};

var skipped = 0, built = 0;

// Note the current panel height BEFORE removing anything, so the rebuilt
// panels keep it instead of dropping to the 30px new-Panel default.
var inherited = 0;
var existing = panelIds;
for (var i = 0; i < existing.length; i++) {
    var ep = panelById(existing[i]);
    if (!inherited && ep.height > 0) inherited = ep.height;
}

var targetHeight = forcedHeight > 0 ? forcedHeight
                 : (inherited > 0 ? inherited : 30);

// Start from a clean slate so every screen ends up identical.
for (var i = 0; i < existing.length; i++) {
    panelById(existing[i]).remove();
}

for (var s = 0; s < screenCount; s++) {
    if (screenGeometry(s).width < minWidth) { skipped++; continue; }

    var panel = new Panel;
    panel.screen     = s;
    panel.location   = "bottom";
    panel.alignment  = "left";
    panel.height     = targetHeight;
    panel.hiding     = "none";
    panel.floating   = true;
    panel.lengthMode = "fill";
    panel.opacity    = "adaptive";

    var kickoff = panel.addWidget("org.kde.plasma.kickoff");
    kickoff.currentConfigGroup = ["General"];
    kickoff.writeConfig("alphaSort", true);
    kickoff.writeConfig("favoritesPortedToKAstats", true);
    kickoff.writeConfig("switchCategoryOnHover", true);
    kickoff.writeConfig("systemFavorites", "suspend,hibernate,reboot,shutdown");

    panel.addWidget("org.kde.plasma.pager");

    var tasks = panel.addWidget("org.kde.plasma.icontasks");
    tasks.currentConfigGroup = ["General"];
    tasks.writeConfig("groupedTaskVisualization", 1);
    tasks.writeConfig("showOnlyCurrentScreen", true);
    tasks.writeConfig("showOnlyCurrentDesktop", false);
    tasks.writeConfig("showOnlyCurrentActivity", false);

    panel.addWidget("org.kde.plasma.marginsseparator");

    // The system tray is itself a containment; its item lists live in the
    // applet's own "General" group, which this wrapper writes to directly.
    var tray = panel.addWidget("org.kde.plasma.systemtray");
    tray.currentConfigGroup = ["General"];
    tray.writeConfig("extraItems", extraItems);
    tray.writeConfig("hiddenItems", hiddenItems);

    var clock = panel.addWidget("org.kde.plasma.digitalclock");
    clock.currentConfigGroup = ["Appearance"];
    clock.writeConfig("enabledCalendarPlugins", "holidaysevents");

    panel.addWidget("org.kde.plasma.showdesktop");

    panel.reloadConfig();
    built++;
}

print("built=" + built + " skipped=" + skipped + " height=" + targetHeight);
JS_EOF
)

    local result
    if result="$("$qdbus_cmd" org.kde.plasmashell /PlasmaShell \
                 org.kde.PlasmaShell.evaluateScript "$js" 2>&1)"; then
        ok "Panels rebuilt (${result:-done})."
        info "Screens narrower than ${min_width}px were skipped."
        info "Pinned launchers were left alone (fresh panels start with the defaults)."
    else
        fail "Plasma rejected the panel script: $result"
    fi
}

# ------------------------------------------------------ 19. wine ------------

install_wine() {
    step "19. Wine"
    # Wine needs the multilib repo for its 32-bit halves.
    if ! grep -qE '^\[multilib\]' /etc/pacman.conf; then
        warn "The [multilib] repository is not enabled in /etc/pacman.conf."
        if ask_yn "Enable [multilib] now (needed for 32-bit Wine support)?" y; then
            sudo cp /etc/pacman.conf "/etc/pacman.conf.bak.$(date +%Y%m%d%H%M%S)"
            sudo sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/ s/^#//' /etc/pacman.conf
            sudo pacman -Syu --noconfirm >/dev/null
            ok "[multilib] enabled."
        else
            warn "Continuing without multilib; Wine will be 64-bit only."
        fi
    fi

    if pac_install "${PKGS_WINE[@]}"; then
        ok "Wine installed."
    else
        fail "Wine install failed."
    fi
}

# ---------------------------------------------- 20. office suite ------------

install_office() {
    step "20. Office suite"
    local picks=() n

    ask_multi "${OFFICE_NAMES[@]}"
    for n in "${SELECTED[@]}"; do
        picks+=( "${OFFICE_IDS[$((n - 1))]}" )
    done

    if (( ${#picks[@]} == 0 )); then
        info "No office suite selected."
        return 0
    fi

    if flatpak_install "${picks[@]}"; then
        ok "Installed: ${picks[*]}"
        # Make LibreOffice use the Qt6 VCL plugin so it matches the Plasma theme.
        if [[ " ${picks[*]} " == *" org.libreoffice.LibreOffice "* ]]; then
            sudo flatpak override --system --env=SAL_USE_VCLPLUGIN=qt6 org.libreoffice.LibreOffice \
                && ok "LibreOffice set to use the Qt6 look."
        fi
    else
        fail "Office suite install failed."
    fi
}

# ------------------------------------------------------------- summary ------

summary() {
    step "Done"
    if (( ${#FAILURES[@]} )); then
        err "${#FAILURES[@]} step(s) reported a problem:"
        local f
        for f in "${FAILURES[@]}"; do err "  - $f"; done
    else
        ok "Everything completed without errors."
    fi
    if (( ${#RUN_STEPS[@]} != ${#STEPS[@]} )); then
        echo
        info "This was a partial run (${#RUN_STEPS[@]} of ${#STEPS[@]} steps)."
        info "Run without --only/--skip to do everything."
    fi

    local body
    if (( ${#FAILURES[@]} )); then
        body="Finished with ${#FAILURES[@]} problem(s) -- check the terminal. Reboot when you have looked them over."
    else
        body="All ${#RUN_STEPS[@]} steps completed. Reboot to finish applying the changes."
    fi

    echo
    printf '%s  Reboot to finish applying the changes.%s\n' "$C_BOLD$C_GREEN" "$C_RESET"
    info "The cursor, window decorations, panels and login screen all settle"
    info "on the next boot. A log out and back in covers most of it, but the"
    info "display manager change needs a full reboot."

    notify_desktop "Post-install setup finished" "$body" \
        || info "(No desktop session to notify -- terminal only.)"
}

# --------------------------------------------- 21. application menu ---------

tidy_application_menu() {
    step "21. Application menu cleanup"

    echo
    info "Some packages add developer and diagnostic tools to the application"
    info "menu that are rarely useful on a desktop:"
    echo
    local entry file label
    for entry in "${MENU_HIDE[@]}"; do
        info "    - ${entry#*|}"
    done
    echo
    info "Hiding them only takes them out of the menu. The programs stay"
    info "installed and still work from a terminal or via \"Open with\"."
    echo

    if ! ask_yn "Hide these entries from the application menu?"; then
        info "Skipped."
        return 0
    fi

    local dest="$HOME/.local/share/applications"
    mkdir -p "$dest"

    local hidden=0 missing=0 src found
    for entry in "${MENU_HIDE[@]}"; do
        file="${entry%%|*}"
        label="${entry#*|}"

        found=""
        for src in "/usr/share/applications/$file" \
                   "/usr/local/share/applications/$file" \
                   "/var/lib/flatpak/exports/share/applications/$file"; do
            [[ -f "$src" ]] && { found="$src"; break; }
        done

        if [[ -z "$found" ]]; then
            (( missing++ ))
            continue
        fi

        # Copy the original first so the override keeps Exec, MimeType and the
        # rest -- a stub would replace the entry outright, not just hide it.
        if cp -f "$found" "$dest/$file" \
           && kwriteconfig6 --file "$dest/$file" --group "Desktop Entry" \
                            --key NoDisplay true; then
            (( hidden++ ))
        else
            fail "Could not hide $label."
        fi
    done

    (( hidden ))  && ok "Hid $hidden of ${#MENU_HIDE[@]} entries from the menu."
    (( missing )) && info "$missing weren't installed; nothing to hide for those."

    # Refresh the caches so the menu updates without needing a re-login.
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$dest" >/dev/null 2>&1
    command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 >/dev/null 2>&1

    return 0
}

# ---------------------------------------------- 22. trash on the desktop ----

# Echo a user's Desktop directory, honouring XDG_DESKTOP_DIR when they have one.
user_desktop_dir() {
    local home="$1" dir=""
    if sudo test -r "$home/.config/user-dirs.dirs"; then
        dir="$(sudo awk -F= '/^[[:space:]]*XDG_DESKTOP_DIR/ {
                   gsub(/"/, "", $2); print $2; exit }' \
               "$home/.config/user-dirs.dirs" 2>/dev/null)"
        dir="${dir/\$HOME/$home}"
    fi
    [[ -n "$dir" ]] || dir="$home/Desktop"
    printf '%s\n' "$dir"
}

add_trash_to_desktops() {
    step "22. Trash icon on the desktop"

    local uid_min=1000 uid_max=60000 v
    if [[ -r /etc/login.defs ]]; then
        v="$(awk '/^UID_MIN/ {print $2; exit}' /etc/login.defs)"; [[ -n "$v" ]] && uid_min="$v"
        v="$(awk '/^UID_MAX/ {print $2; exit}' /etc/login.defs)"; [[ -n "$v" ]] && uid_max="$v"
    fi

    local tmp="$WORKDIR/trash.desktop"
    cat > "$tmp" <<'EOF'
[Desktop Entry]
EmptyIcon=user-trash
Icon=user-trash-full
Name=Trash
Type=Link
URL[$e]=trash:/
EOF

    local user uid home shell grp desktop
    local added=0 already=0 skipped=0

    while IFS=: read -r user _ uid _ _ home shell; do
        (( uid >= uid_min && uid <= uid_max )) || continue
        case "$shell" in */nologin|*/false|"") continue ;; esac
        if [[ ! -d "$home" ]]; then
            warn "$user: no home directory at $home -- skipped."
            (( skipped++ )); continue
        fi

        desktop="$(user_desktop_dir "$home")"
        grp="$(id -gn "$user" 2>/dev/null)" || grp="$user"

        if sudo test -e "$desktop/$TRASH_DESKTOP_NAME"; then
            info "$user: already has a Trash icon."
            (( already++ )); continue
        fi

        # Only create the folder when it is genuinely missing, so an existing
        # one keeps its own ownership and mode.
        if ! sudo test -d "$desktop"; then
            if ! sudo install -d -o "$user" -g "$grp" -m 0755 "$desktop"; then
                fail "$user: could not create $desktop."
                (( skipped++ )); continue
            fi
        fi

        if sudo install -o "$user" -g "$grp" -m 0644 \
                "$tmp" "$desktop/$TRASH_DESKTOP_NAME"; then
            ok "$user: Trash icon added to ${desktop}."
            (( added++ ))
        else
            fail "$user: could not write the Trash icon."
            (( skipped++ ))
        fi
    done < /etc/passwd

    info "Trash icon: $added added, $already already present, $skipped skipped."

    # New accounts have their home seeded from /etc/skel, so seed that too.
    # These files stay root-owned; useradd reassigns them when it copies them.
    local skel="/etc/skel/Desktop"
    if sudo test -e "$skel/$TRASH_DESKTOP_NAME"; then
        info "/etc/skel already has a Trash icon."
    else
        if ! sudo test -d "$skel" && ! sudo install -d -m 0755 "$skel"; then
            fail "Could not create $skel."
            return 0
        fi
        if sudo install -m 0644 "$tmp" "$skel/$TRASH_DESKTOP_NAME"; then
            ok "/etc/skel seeded, so new accounts get the icon too."
        else
            fail "Could not add the Trash icon to /etc/skel."
        fi
    fi
}

# ---------------------------------------------------------------- main ------

main() {
    parse_args "$@"
    show_intro

    preflight

    # Steps 9 and 11 are the ones that read files out of the payload.
    if step_selected 9 || step_selected 11; then
        fetch_payload
    fi

    local n fn
    for n in "${RUN_STEPS[@]}"; do
        fn="$(step_field "$n" fn)"
        "$fn"
    done

    summary
}

main "$@"
