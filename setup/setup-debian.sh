#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# --------------------------------------------------------------
# Library
# --------------------------------------------------------------

source $SCRIPT_DIR/_lib.sh

# --------------------------------------------------------------
# General Packages
# --------------------------------------------------------------

source $SCRIPT_DIR/pkgs.sh

# --------------------------------------------------------------
# Detect Debian variant (PikaOS vs Ubuntu vs Debian)
# --------------------------------------------------------------

_detectDebianVariant() {
    if grep -q "pika" /etc/apt/sources.list.d/*.sources 2>/dev/null; then
        echo "pikaos"
    elif grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
        echo "ubuntu"
    else
        echo "debian"
    fi
}

DISTRO_VARIANT=$(_detectDebianVariant)

# --------------------------------------------------------------
# Distro related packages (Debian/Ubuntu specific names)
# --------------------------------------------------------------

packages=(
    # Python
    "python3-pip"
    "python3-gi"
    "libgirepository-2.0-dev"  # Required for PyGObject (waypaper dependency)
    # Tools
    "libnotify-bin"
    "qtwayland5"
    "qt6-wayland"
    "wl-clipboard"
    "imagemagick"
    "network-manager-gnome"
    # Notification
    "sway-notification-center"
    # Fonts
    "fonts-font-awesome"
    "fonts-firacode"
)

# Packages that need different names on Debian vs pkgs.sh
packages_override=(
    "breeze-cursor-theme"  # replaces 'breeze' from pkgs.sh
)

# --------------------------------------------------------------
# Check if package is installed
# --------------------------------------------------------------

_isInstalled() {
    package="$1"
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
        echo 0
        return
    else
        echo 1
        return
    fi
}

# --------------------------------------------------------------
# Install packages
# --------------------------------------------------------------

_installPackages() {
    local to_install=()
    for pkg in "$@"; do
        if [[ $(_isInstalled "${pkg}") == 0 ]]; then
            echo "${pkg} is already installed."
            continue
        fi
        to_install+=("$pkg")
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        sudo apt install -y "${to_install[@]}"
    fi
}

# --------------------------------------------------------------
# Setup repositories (Ubuntu/Debian only - PikaOS has everything)
# --------------------------------------------------------------

_setupRepos() {
    if [[ "$DISTRO_VARIANT" == "ubuntu" ]]; then
        echo ":: Setting up Ubuntu repositories..."

        # Add Hyprland PPA
        if ! grep -q "cppiber/hyprland" /etc/apt/sources.list.d/* 2>/dev/null; then
            echo ":: Adding Hyprland PPA..."
            sudo add-apt-repository -y ppa:cppiber/hyprland
        fi

        # Add Charm repo for gum
        if ! [ -f /etc/apt/keyrings/charm.gpg ]; then
            echo ":: Adding Charm repository for gum..."
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
            echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
        fi

        sudo apt update
    elif [[ "$DISTRO_VARIANT" == "debian" ]]; then
        echo ":: Debian detected - you may need to manually add repositories for some packages"
        echo ":: See: https://mylinuxforwork.github.io/dotfiles/getting-started/dependencies"
    fi
    # PikaOS has all packages in their repos - no additional setup needed
}

# --------------------------------------------------------------
# Build nwg-dock-hyprland from source
# --------------------------------------------------------------

_buildNwgDockHyprland() {
    if command -v nwg-dock-hyprland &> /dev/null; then
        echo ":: nwg-dock-hyprland is already installed"
        return 0
    fi

    echo ":: Building nwg-dock-hyprland from source..."

    # Install build dependencies
    sudo apt install -y golang-go libgtk-3-dev libgtk-layer-shell-dev libgirepository1.0-dev

    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    git clone --depth 1 https://github.com/nwg-piotr/nwg-dock-hyprland.git
    cd nwg-dock-hyprland
    # Use parallel build for Go
    go build -p $(nproc) -v -o bin/nwg-dock-hyprland .
    sudo install -Dm755 bin/nwg-dock-hyprland /usr/local/bin/nwg-dock-hyprland
    cd ~
    rm -rf "$TEMP_DIR"

    echo ":: nwg-dock-hyprland installed successfully"
}

# --------------------------------------------------------------
# Build hyprpicker from source (not in Debian/PikaOS repos)
# --------------------------------------------------------------

_buildHyprpicker() {
    if command -v hyprpicker &> /dev/null; then
        echo ":: hyprpicker is already installed"
        return 0
    fi

    echo ":: Building hyprpicker from source..."

    # Install build dependencies (PikaOS package names)
    sudo apt install -y cmake pkg-config libcairo2-dev libpango1.0-dev \
        libjpeg-dev libwayland-dev wayland-protocols libxkbcommon-dev \
        libhyprutils-dev hyprwayland-scanner

    # PikaOS hyprwayland-scanner only provides CMake config, not pkg-config
    # Create a minimal .pc file so hyprpicker's CMakeLists.txt can find it
    if ! pkg-config --exists hyprwayland-scanner; then
        echo ":: Creating pkg-config file for hyprwayland-scanner..."
        SCANNER_VERSION=$(hyprwayland-scanner --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "0.4.5")
        sudo tee /usr/lib/x86_64-linux-gnu/pkgconfig/hyprwayland-scanner.pc > /dev/null <<EOF
prefix=/usr
bindir=\${prefix}/bin

Name: hyprwayland-scanner
Description: Hyprland wayland protocol scanner
Version: $SCANNER_VERSION
EOF
    fi

    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"

    if ! git clone --depth 1 https://github.com/hyprwm/hyprpicker.git; then
        echo ":: Error: Failed to clone hyprpicker repository"
        cd ~
        rm -rf "$TEMP_DIR"
        return 1
    fi

    cd hyprpicker

    if ! cmake -B build; then
        echo ":: Error: CMake configuration failed"
        cd ~
        rm -rf "$TEMP_DIR"
        return 1
    fi

    if ! cmake --build build -j $(nproc); then
        echo ":: Error: Build failed"
        cd ~
        rm -rf "$TEMP_DIR"
        return 1
    fi

    if ! sudo cmake --install build; then
        echo ":: Error: Installation failed"
        cd ~
        rm -rf "$TEMP_DIR"
        return 1
    fi

    cd ~
    rm -rf "$TEMP_DIR"

    echo ":: hyprpicker installed successfully"
    return 0
}

# --------------------------------------------------------------
# Gum
# --------------------------------------------------------------

if [[ $(_checkCommandExists "gum") == 0 ]]; then
    echo ":: gum is already installed"
else
    echo ":: The installer requires gum. gum will be installed now"
    if [[ "$DISTRO_VARIANT" == "pikaos" ]]; then
        sudo apt install -y gum
    else
        # For Ubuntu/Debian, add Charm repo first
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
        sudo apt update
        sudo apt install -y gum
    fi
fi

# --------------------------------------------------------------
# Header
# --------------------------------------------------------------

_writeHeader "Debian/Ubuntu ($DISTRO_VARIANT)"

# --------------------------------------------------------------
# Setup Repositories
# --------------------------------------------------------------

_setupRepos

# --------------------------------------------------------------
# General
# --------------------------------------------------------------

echo ":: Installing general packages..."
_installPackages "${general[@]}"

# --------------------------------------------------------------
# Apps (excluding nwg-dock-hyprland which needs building)
# --------------------------------------------------------------

echo ":: Installing applications..."
# Filter out nwg-dock-hyprland from apps array
apps_filtered=()
for pkg in "${apps[@]}"; do
    if [[ "$pkg" != "nwg-dock-hyprland" ]]; then
        apps_filtered+=("$pkg")
    fi
done
_installPackages "${apps_filtered[@]}"

# --------------------------------------------------------------
# Tools (with Debian name overrides)
# --------------------------------------------------------------

echo ":: Installing tools..."
# Filter out 'breeze' (replaced by breeze-cursor-theme in packages array)
tools_filtered=()
for pkg in "${tools[@]}"; do
    if [[ "$pkg" != "breeze" ]]; then
        tools_filtered+=("$pkg")
    fi
done
_installPackages "${tools_filtered[@]}"

# --------------------------------------------------------------
# Distro-specific Packages
# --------------------------------------------------------------

echo ":: Installing Debian-specific packages..."
_installPackages "${packages[@]}"
_installPackages "${packages_override[@]}"

# --------------------------------------------------------------
# Hyprland (filter out hyprpicker - we build it from source)
# --------------------------------------------------------------

echo ":: Installing Hyprland packages..."
hyprland_filtered=()
for pkg in "${hyprland[@]}"; do
    if [[ "$pkg" != "hyprpicker" ]]; then
        hyprland_filtered+=("$pkg")
    fi
done
_installPackages "${hyprland_filtered[@]}"

# --------------------------------------------------------------
# Build packages from source
# --------------------------------------------------------------

_buildNwgDockHyprland
_buildHyprpicker

# --------------------------------------------------------------
# Create .local/bin folder
# --------------------------------------------------------------

if [ ! -d $HOME/.local/bin ]; then
    mkdir -p $HOME/.local/bin
fi

# --------------------------------------------------------------
# Oh My Posh
# --------------------------------------------------------------

curl -s https://ohmyposh.dev/install.sh | bash -s -- -d ~/.local/bin

# --------------------------------------------------------------
# Prebuild Packages
# --------------------------------------------------------------

source $SCRIPT_DIR/_prebuilt.sh

# eza is available in PikaOS repos, install via apt if not present
if [[ $(_checkCommandExists "eza") == 0 ]]; then
    echo ":: eza is already installed"
else
    if [[ "$DISTRO_VARIANT" == "pikaos" ]]; then
        sudo apt install -y eza
    else
        # For other distros, use prebuilt
        echo ":: Installing eza from prebuilt..."
        sudo cp $SCRIPT_DIR/packages/eza /usr/bin
    fi
fi

# --------------------------------------------------------------
# Python tools via pipx (proper isolation, no system pollution)
# --------------------------------------------------------------

echo ":: Installing Python tools via pipx"

# Ensure pipx is installed
if ! command -v pipx &> /dev/null; then
    sudo apt install -y pipx
fi

# Ensure pipx paths are set up
pipx ensurepath

# Install Python CLI tools in isolated environments
pipx install hyprshade || pipx upgrade hyprshade
pipx install pywalfox || pipx upgrade pywalfox
pipx install waypaper || pipx upgrade waypaper
pipx install pywal || pipx upgrade pywal

# screeninfo is a library - use system package
sudo apt install -y python3-screeninfo

# Setup pywalfox for Firefox integration
if command -v pywalfox &> /dev/null; then
    pywalfox install
elif [ -f "$HOME/.local/bin/pywalfox" ]; then
    "$HOME/.local/bin/pywalfox" install
else
    echo ":: Warning: pywalfox not found, skipping Firefox integration"
fi

# --------------------------------------------------------------
# ML4W Apps
# --------------------------------------------------------------

source $SCRIPT_DIR/_ml4w-apps.sh

# --------------------------------------------------------------
# Flatpaks
# --------------------------------------------------------------

source $SCRIPT_DIR/_flatpaks.sh

# --------------------------------------------------------------
# Grimblast
# --------------------------------------------------------------

sudo cp $SCRIPT_DIR/scripts/grimblast /usr/bin

# --------------------------------------------------------------
# Cursors
# --------------------------------------------------------------

source $SCRIPT_DIR/_cursors.sh

# --------------------------------------------------------------
# Fonts
# --------------------------------------------------------------

source $SCRIPT_DIR/_fonts.sh

# --------------------------------------------------------------
# Icons
# --------------------------------------------------------------

source $SCRIPT_DIR/_icons.sh

# --------------------------------------------------------------
# Finish
# --------------------------------------------------------------

_finishMessage
