#!/bin/bash
# install_rocm_deps.sh
#
# Installs runtime dependencies for ROCm on various Linux distributions.
# Automatically detects the distribution and uses the appropriate package manager.
#
# Supported distributions:
#   - Ubuntu 22.04, 24.04 (apt)
#   - AlmaLinux 8, CentOS, Rocky Linux (dnf)
#   - Azure Linux 3, CBL-Mariner (tdnf)

set -e

# Detect distribution type from /etc/os-release
detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

DISTRO=$(detect_distro)
echo "Detected distribution: $DISTRO"

case "$DISTRO" in
    ubuntu|debian)
        echo "Installing dependencies using apt..."
        apt-get update
        apt-get install -y --no-install-recommends \
            ca-certificates \
            wget \
            libelf1 \
            libnuma1 \
            python3 \
            python3-pip \
            python3-venv \
            kmod \
            pciutils
        rm -rf /var/lib/apt/lists/*
        ;;

    almalinux|centos|rocky)
        echo "Installing dependencies using dnf..."
        dnf install -y --setopt=install_weak_deps=False \
            ca-certificates \
            wget \
            elfutils-libelf \
            numactl-libs \
            python3 \
            python3-pip \
            kmod \
            pciutils
        dnf clean all
        ;;

    azurelinux|mariner)
        echo "Installing dependencies using tdnf..."
        tdnf install -y \
            ca-certificates \
            wget \
            elfutils-libelf \
            numactl-libs \
            python3 \
            python3-pip \
            kmod \
            pciutils
        tdnf clean all
        ;;

    *)
        echo "Error: Unsupported distribution: $DISTRO"
        echo "Supported distributions: ubuntu, debian, almalinux, centos, rocky, azurelinux, mariner"
        exit 1
        ;;
esac

echo "Dependencies installed successfully for $DISTRO"

