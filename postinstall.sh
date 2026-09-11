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
    ark dolphin dolphin-plugins filelight gwenview isoimagewriter kate kcalc
    kcharselect kclock kcron kdf kdialog kjournald kolourpaint konsole ksystemlog
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
    drkonqi polkit-kde-agent kwallet-pam sddm-kcm kgamma spectacle
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

# Populated as the run goes, so later steps know what actually got installed.
INSTALL_FLOORP=0
INSTALL_THUNDERBIRD=0
INSTALL_GAMES=0

pac_install() {
    (( $# )) || return 0
    sudo pacman -S --needed --noconfirm "$@"
}

flatpak_install() {
    (( $# )) || return 0
    sudo flatpak install -y --system --noninteractive flathub "$@"
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
    for c in curl tar sudo; do
        command -v "$c" >/dev/null || { err "Missing required tool: $c"; exit 1; }
    done

    info "Caching sudo credentials..."
    sudo -v || { err "sudo failed."; exit 1; }
    # Keep sudo alive for the whole run.
    while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &

    # A bare `pacman -Sy` followed by `-S` is a partial upgrade, which Arch
    # warns against, so bring the whole system up to date instead.
    info "Synchronising databases and updating the system..."
    if sudo pacman -Syu --noconfirm; then
        ok "System up to date."
    else
        warn "Full upgrade had trouble; continuing anyway."
    fi
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

# ------------------------------------------------------- 1. bluetooth -------

setup_bluetooth() {
    step "1. Bluetooth"
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

# Walk grub.cfg and emit "<GRUB_DEFAULT value>|<vmlinuz path>" for every entry,
# building the "submenu_id>entry_id" form for nested entries.
grub_entry_map() {
    sudo awk '
        function id_of(line,   n, a) {
            # menuentry ids are emitted as: $menuentry_id_option '\''some-id'\''
            n = index(line, "menuentry_id_option")
            if (n == 0) return ""
            a = substr(line, n)
            n = index(a, "'\''")
            if (n == 0) return ""
            a = substr(a, n + 1)
            n = index(a, "'\''")
            if (n == 0) return ""
            return substr(a, 1, n - 1)
        }
        /^[[:space:]]*submenu[[:space:]]/ { sub_id = id_of($0); next }
        /^[[:space:]]*menuentry[[:space:]]/ {
            cur = id_of($0)
            if (sub_id != "" && match($0, /^[[:space:]]+menuentry/)) cur = sub_id ">" cur
            next
        }
        /^[[:space:]]*}/ { if (sub_id != "" && $0 !~ /^[[:space:]]+}/) sub_id = "" ; next }
        /^[[:space:]]*linux(16|efi)?[[:space:]]/ {
            if (cur != "") { print cur "|" $2; cur = "" }
        }
    ' /boot/grub/grub.cfg
}

setup_grub_default() {
    local latest_img="$1" latest_base entry target=""
    latest_base="$(basename "$latest_img")"

    info "Regenerating grub.cfg so the menu reflects the installed kernels..."
    sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 \
        || { fail "grub-mkconfig failed"; return 1; }

    while IFS='|' read -r entry kernelpath; do
        [[ "$(basename "$kernelpath")" == "$latest_base" ]] || continue
        # Prefer a top-level entry; only fall back to a nested one.
        if [[ "$entry" != *">"* ]]; then target="$entry"; break; fi
        [[ -z "$target" ]] && target="$entry"
    done < <(grub_entry_map)

    if [[ -z "$target" ]]; then
        fail "Could not find a GRUB entry for $latest_base; leaving GRUB_DEFAULT alone."
        return 1
    fi

    info "Setting GRUB_DEFAULT to '$target'"
    sudo cp /etc/default/grub "/etc/default/grub.bak.$(date +%Y%m%d%H%M%S)"
    if grep -qE '^[[:space:]]*GRUB_DEFAULT=' /etc/default/grub; then
        sudo sed -i "s|^[[:space:]]*GRUB_DEFAULT=.*|GRUB_DEFAULT='${target}'|" /etc/default/grub
    else
        printf "GRUB_DEFAULT='%s'\n" "$target" | sudo tee -a /etc/default/grub >/dev/null
    fi

    # GRUB_DEFAULT is read at generation time, so regenerate once more.
    sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 \
        || { fail "second grub-mkconfig failed"; return 1; }
    ok "GRUB now boots $latest_base by default."
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
    step "2. Default boot kernel"

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
    step "3. Core packages (KDE, Plasma, Discover, Flatpak, portals)"
    info "Installing ${#PKGS_BASE[@]} packages -- this takes a while."
    if pac_install "${PKGS_BASE[@]}"; then
        ok "Core packages installed."
    else
        fail "Some core packages failed to install."
    fi

    # Flathub must exist before any of the flatpak steps below.
    if command -v flatpak >/dev/null; then
        sudo flatpak remote-add --if-not-exists --system \
            flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 \
            && ok "Flathub remote configured." \
            || fail "Could not add the Flathub remote."
    fi
}

# ------------------------------------------------ 4/5. browsers + Floorp ----

install_browsers() {
    step "4. Browsers (Flatpak)"
    local i picks=() chosen=() n
    echo
    for i in "${!BROWSER_NAMES[@]}"; do
        printf '      %d) %s\n' $((i+1)) "${BROWSER_NAMES[$i]}"
    done
    echo
    info "Enter the numbers you want, space separated (e.g. \"1 3\"), or blank for none."
    read -r -p "    Selection: " -a picks </dev/tty

    for n in "${picks[@]}"; do
        [[ "$n" =~ ^[0-9]+$ ]] || { warn "Ignoring '$n'."; continue; }
        if (( n < 1 || n > ${#BROWSER_IDS[@]} )); then warn "Ignoring '$n'."; continue; fi
        chosen+=( "${BROWSER_IDS[$((n-1))]}" )
        [[ "${BROWSER_IDS[$((n-1))]}" == "one.ablaze.floorp" ]] && INSTALL_FLOORP=1
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
    step "6. Thunderbird"
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
    step "7. Deploying the loose/ configuration files"
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

    # --- Window decoration theme (step 11 applies it) ---
    if [[ -d "$LOOSE/Window Decorations/WillowDark" ]]; then
        mkdir -p "$HOME/.local/share/aurorae/themes"
        cp -r "$LOOSE/Window Decorations/WillowDark" "$HOME/.local/share/aurorae/themes/"
        ok "Willow Dark -> ~/.local/share/aurorae/themes/WillowDark"
    fi

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
    step "8. KDE games"
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
    step "9. Dolphin settings"
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

# ---------------------------------------------------------- 10. cursor ------

configure_cursor() {
    step "10. Cursor theme (Breeze Light)"
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
    step "11. Window decorations (Willow Dark)"
    local theme_dir="$HOME/.local/share/aurorae/themes/WillowDark"

    if [[ ! -d "$theme_dir" ]]; then
        fail "WillowDark aurorae theme is missing; skipping."
        return 1
    fi

    local f="$HOME/.config/kwinrc"
    kw "$f" org.kde.kdecoration2 library org.kde.kwin.aurorae.v2
    kw "$f" org.kde.kdecoration2 theme "__aurorae__svg__WillowDark"
    kw "$f" org.kde.kdecoration2 ButtonsOnLeft "M"

    # Ask KWin to pick it up now if a session is running.
    qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 \
        || qdbus org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true

    ok "Willow Dark set as the window decoration."
}

# ---------------------------------------------------------- 12. printing ----

setup_printing() {
    step "12. Printing (CUPS)"
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
    step "13. Spell checking (Sonnet + Hunspell)"
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
    step "14. Panels and system tray on every monitor"

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

    local js
    js=$(cat <<JS_EOF
var extraItems  = "${extra_items}";
var hiddenItems = "${hidden_items}";
var minWidth    = ${min_width};

var skipped = 0, built = 0;

// Start from a clean slate so every screen ends up identical.
var existing = panelIds;
for (var i = 0; i < existing.length; i++) {
    panelById(existing[i]).remove();
}

for (var s = 0; s < screenCount; s++) {
    if (screenGeometry(s).width < minWidth) { skipped++; continue; }

    var panel = new Panel;
    panel.screen     = s;
    panel.location   = "bottom";
    panel.alignment  = "left";
    // Panel height is deliberately left at the Plasma default.
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

print("built=" + built + " skipped=" + skipped);
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
    step "15. Wine"
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
    step "16. Office suite"
    echo
    info "  1) LibreOffice      -- tried and true"
    info "  2) Collabora Office -- newer, closer to the Microsoft Office look"
    info "  3) Both"
    info "  4) Neither"
    echo
    local choice picks=()
    read -r -p "    Selection [4]: " choice </dev/tty
    choice="${choice:-4}"

    case "$choice" in
        1) picks=( org.libreoffice.LibreOffice ) ;;
        2) picks=( com.collaboraoffice.Office ) ;;
        3) picks=( org.libreoffice.LibreOffice com.collaboraoffice.Office ) ;;
        4|"") info "Skipped."; return 0 ;;
        *) warn "Unrecognised choice '$choice' -- skipping."; return 0 ;;
    esac

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
    printf '%s\n' "$C_BOLD${C_BLUE}Arch Linux post-install setup$C_RESET"

    preflight
    fetch_payload

    setup_bluetooth        # 1
    setup_bootloader       # 2
    install_base_packages  # 3
    install_browsers       # 4 + 5
    install_thunderbird    # 6
    deploy_loose_files     # 7
    install_games          # 8
    configure_dolphin      # 9
    configure_cursor       # 10
    configure_decorations  # 11
    setup_printing         # 12
    setup_spellcheck       # 13
    configure_panels       # 14
    install_wine           # 15
    install_office         # 16

    summary
}

main "$@"
