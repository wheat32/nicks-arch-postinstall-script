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
err()   { printf '    %s%s%s\n' "$C_RED" "$*" "$C_RESET"; }

fail() { err "$*"; FAILURES+=("$*"); }

cleanup() { [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

# -r on /dev/tty is not enough: the file can exist and still fail to open when
# there is no controlling terminal. Actually try it.
have_tty() { { : </dev/tty; } 2>/dev/null; }

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
    info "Enter the numbers you want, space separated (e.g. \"1 2\"), or blank for none."
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

# Superseded packages. Photos (package name "koko") is proposed as Gwenview's
# replacement as of KDE Gear 26.08, so install that instead and take Gwenview
# back off the system if an earlier install left it there.
PKGS_REMOVE=( gwenview )

PKGS_PRINT=(
    cups cups-browsed cups-filters cups-pdf
    foomatic-db foomatic-db-engine foomatic-db-ppds
    foomatic-db-gutenprint-ppds foomatic-db-nonfree foomatic-db-nonfree-ppds
    ghostscript gsfonts gutenprint system-config-printer python-pycups
)

# Sonnet (the KDE spell-checking framework) backs onto hunspell/aspell/enchant.
PKGS_SPELL=( hunspell hunspell-en_us aspell enchant )

PKGS_WINE=( wine wine-mono winetricks )

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

# Populated as the run goes, so later steps know what actually got installed.
INSTALL_FLOORP=0
INSTALL_THUNDERBIRD=0
INSTALL_GAMES=0

# Set by choose_theme_mode(); everything appearance-related keys off these.
THEME_MODE="dark"
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

# --------------------------------------------------------------- intro ------

show_intro() {
    printf '\n%sArch Linux post-install setup%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
    printf '%s\n' "-------------------------------------------------------------"
    cat <<'INTRO'

  This sets up a fresh Arch Linux + KDE Plasma install. It will:

     1.  Add the Chaotic-AUR repository
     2.  Fully update the system
     3.  Enable and start Bluetooth
     4.  Point the bootloader at the newest installed kernel
     5.  Install the KDE/Plasma packages, Discover, Flatpak and XDG portals
     6.  Install the browsers you pick, as Flatpaks
     7.  Install Thunderbird, if you want it
     8.  Drop the userChrome.css files and window decorations into place
     9.  Install the KDE games, if you want them
    10.  Apply your Dolphin settings
    11.  Apply light or dark mode
    12.  Set the Breeze Light cursor
    13.  Apply the Willow window decorations
    14.  Install and enable printing (CUPS, foomatic, gutenprint)
    15.  Install Hunspell and configure spell checking for en_US
    16.  Rebuild a matching panel and system tray on every monitor
    17.  Install Wine
    18.  Install an office suite, if you want one

  You will be asked about:

    - Which browsers you want (Floorp, Firefox, Ungoogled Chromium, Brave)
    - Thunderbird
    - The KDE games
    - Light or dark mode
    - Which office suites you want (LibreOffice, Collabora Office)

  Worth knowing before you start:

    - It adds the Chaotic-AUR repository: this imports and locally signs
      that project's GPG key and installs its keyring from its CDN
    - It makes Plasma Login Manager your display manager, disabling any
      existing one; this takes effect on the next reboot
    - It then runs a full system upgrade (pacman -Syu)
    - It asks for your sudo password up front, and keeps it alive
    - /etc/pacman.conf is backed up before it is edited
    - /etc/default/grub is backed up before it is edited
    - Your Plasma panels are deleted and rebuilt, which resets pinned
      launchers back to the defaults
    - Configuration files are downloaded from GitHub, not read from disk

  Nothing has been changed yet.

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

    info "Caching sudo credentials..."
    sudo -v || { err "sudo failed."; exit 1; }
    # Keep sudo alive for the whole run.
    while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &

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

# ------------------------------------------------------- 1. bluetooth -------

setup_bluetooth() {
    step "3. Bluetooth"
    pac_install bluez bluez-utils || fail "bluez install failed"
    if sudo systemctl enable --now bluetooth.service; then
        ok "bluetooth.service enabled and started."
    else
        fail "Could not enable/start bluetooth.service"
    fi
}

# ------------------------------------------------- 2. bootloader default ----

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

# Highest-versioned kernel, via pacman's own version comparison.
# Echoes the same four fields as list_kernels.
latest_kernel() {
    local best="" best_ver="" ver rest
    while read -r ver rest; do
        [[ -z "$ver" ]] && continue
        if [[ -z "$best_ver" ]] || [[ "$(vercmp "$ver" "$best_ver")" -gt 0 ]]; then
            best_ver="$ver"; best="$ver $rest"
        fi
    done < <(list_kernels)
    printf '%s\n' "$best"
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
    local latest_img="$1" latest_base entry pos id kernel target="" current
    latest_base="$(basename "$latest_img")"

    if [[ ! -r /boot/grub/grub.cfg ]] && ! sudo test -r /boot/grub/grub.cfg; then
        fail "/boot/grub/grub.cfg is not readable; leaving GRUB alone."
        return 1
    fi

    # Nothing to do if the existing default already boots the newest kernel.
    # This is the common case on a system that is already set up correctly,
    # and it means the script does not touch GRUB at all.
    if current="$(grub_current_kernel)" && [[ "$(basename "$current")" == "$latest_base" ]]; then
        ok "GRUB already boots $latest_base by default; leaving it untouched."
        return 0
    fi

    # Read the menu as it stands -- no pre-emptive regeneration.
    while IFS='|' read -r pos id kernel; do
        [[ "$(basename "$kernel")" == "$latest_base" ]] || continue
        if [[ "$id" != *">"* ]]; then target="$id"; break; fi
        [[ -z "$target" ]] && target="$id"
    done < <(grub_entry_map)

    if [[ -z "$target" ]]; then
        fail "No GRUB entry for $latest_base in the current menu; leaving GRUB alone."
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

    ok "GRUB now boots $latest_base by default (background/theme preserved)."
}

setup_sdboot_default() {
    local latest_img="$1" latest_pkgbase="$2" latest_kver="$3"
    local latest_base esp entry line best=""
    latest_base="$(basename "$latest_img")"
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
        if [[ "$line" == *"$latest_base"* || "$line" == *"/$latest_pkgbase"* \
              || "$line" == *"$latest_kver"* ]]; then
            best="$(basename "$entry")"
            # Prefer a normal entry over a fallback one.
            [[ "$best" == *fallback* ]] || break
        fi
    done

    if [[ -z "$best" ]]; then
        fail "No systemd-boot entry references $latest_base; leaving loader.conf alone."
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
    step "4. Default boot kernel"

    local count ver img pkgbase kver v i b k
    count="$(list_kernels | wc -l)"
    if (( count < 2 )); then
        info "Only $count kernel installed -- nothing to choose between. Skipping."
        return 0
    fi

    info "Kernels found:"
    while read -r v i b k; do info "  $b  ($v)"; done < <(list_kernels)

    read -r ver img pkgbase kver < <(latest_kernel)
    if [[ -z "${img:-}" ]]; then
        fail "Could not determine the newest kernel."
        return 1
    fi
    info "Newest: $pkgbase ($ver)"

    if [[ -d /boot/grub ]] && command -v grub-mkconfig >/dev/null; then
        setup_grub_default "$img"
    elif command -v bootctl >/dev/null && bootctl is-installed >/dev/null 2>&1; then
        setup_sdboot_default "$img" "$pkgbase" "$kver"
    else
        warn "Neither GRUB nor systemd-boot detected. Skipping."
    fi
}

# ---------------------------------------------------- 3. base packages ------

install_base_packages() {
    step "5. Core packages (KDE, Plasma, Discover, Flatpak, portals)"
    info "Installing ${#PKGS_BASE[@]} packages -- this takes a while."
    if pac_install "${PKGS_BASE[@]}"; then
        ok "Core packages installed."
    else
        fail "Some core packages failed to install."
    fi

    # Photos (koko) is installed above in Gwenview's place.
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

    local current=""
    if [[ -e /etc/systemd/system/display-manager.service ]]; then
        current="$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")"
    fi

    if [[ "$current" == "plasmalogin.service" ]]; then
        ok "Plasma Login Manager is already the display manager."
        return 0
    fi

    if [[ -n "$current" ]]; then
        info "Disabling the current display manager ($current)..."
        sudo systemctl disable "$current" >/dev/null 2>&1 \
            || warn "Could not disable $current; enabling may fail."
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
    step "6. Browsers (Flatpak)"
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

# ------------------------------------------------------ 6. Thunderbird ------

install_thunderbird() {
    step "7. Thunderbird"
    if ask_yn "Install Thunderbird (Flatpak)?"; then
        if flatpak_install org.mozilla.Thunderbird; then
            INSTALL_THUNDERBIRD=1
            ok "Thunderbird installed."
        else
            fail "Thunderbird install failed."
        fi
    else
        info "Skipped."
    fi
}

# ------------------------------------------- 7. deploy loose/ config files ---

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
    step "8. Deploying the loose/ configuration files"
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

    # --- Thunderbird (the Flatpak id has been spelled both ways over time) ---
    local tb_root="" r
    for r in "$HOME/.var/app/org.mozilla.Thunderbird/.thunderbird" \
             "$HOME/.var/app/org.mozilla.thunderbird/.thunderbird" \
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

# ----------------------------------------------------------- 8. games -------

install_games() {
    step "9. KDE games"
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

# ---------------------------------------------------------- 9. dolphin ------

configure_dolphin() {
    step "10. Dolphin settings"
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
    kw "$f" PreviewSettings Plugins \
        "ffmpegthumbnailer,appimagethumbnail,audiothumbnail,blenderthumbnail,comicbookthumbnail,cursorthumbnail,djvuthumbnail,ebookthumbnail,exrthumbnail,directorythumbnail,fontthumbnail,imagethumbnail,jpegthumbnail,kraorathumbnail,windowsexethumbnail,windowsimagethumbnail,mobithumbnail,opendocumentthumbnail,gsthumbnail,rawthumbnail,svgthumbnail,ffmpegthumbs,gdk-pixbuf-thumbnailer,gsf-office"

    ok "dolphinrc written."
}

# ------------------------------------------- light / dark mode + appearance --

choose_theme_mode() {
    step "11. Light or dark mode"
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
    ok "Using ${THEME_MODE} mode."
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

# ---------------------------------------------------------- 10. cursor ------

configure_cursor() {
    step "12. Cursor theme (Breeze Light)"
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

# ----------------------------------------------- 11. window decorations -----

configure_decorations() {
    step "13. Window decorations ($DECORATION_THEME)"
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

# ---------------------------------------------------------- 12. printing ----

setup_printing() {
    step "14. Printing (CUPS)"
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

# ------------------------------------------------------ 13. spellchecker ----

setup_spellcheck() {
    step "15. Spell checking (Sonnet + Hunspell)"
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

# ------------------------------------------------- 14. panels + systray -----

configure_panels() {
    step "16. Panels and system tray on every monitor"

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

# ------------------------------------------------------------ 15. wine ------

install_wine() {
    step "17. Wine"
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

# ------------------------------------------------------ 16. office suite ----

install_office() {
    step "18. Office suite"
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
    echo
    info "Log out and back in (or reboot) so the cursor, window decorations,"
    info "and panel changes take full effect."
}

# ---------------------------------------------------------------- main ------

main() {
    show_intro

    preflight
    fetch_payload

    setup_chaotic_aur      # 1
    system_update          # 2
    setup_bluetooth        # 3
    setup_bootloader       # 4
    install_base_packages  # 5
    install_browsers       # 6  (also grants Floorp access to $HOME)
    install_thunderbird    # 7
    deploy_loose_files     # 8
    install_games          # 9
    configure_dolphin      # 10
    choose_theme_mode      # 11
    apply_theme_mode       #     (continues step 11)
    configure_cursor       # 12
    configure_decorations  # 13
    setup_printing         # 14
    setup_spellcheck       # 15
    configure_panels       # 16
    install_wine           # 17
    install_office         # 18

    summary
}

main "$@"
