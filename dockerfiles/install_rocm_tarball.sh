#!/bin/bash
# install_rocm_tarball.sh
#
# Downloads and installs ROCm from a tarball.
# Supports nightly builds with architecture for future extension to prerelease and dev.
#
# The tarball is extracted to a versioned directory based on VERSION.
# For example, with version 7.11.0a20251209:
#   - Install directory: /opt/rocm-7.11.0a20251209/
#   - Symlink: /opt/rocm -> /opt/rocm-7.11.0a20251209
#
# Usage:
#   ./install_rocm_tarball.sh <VERSION> <AMDGPU_FAMILY> [RELEASE_TYPE] [TARBALL_URL]
#
# Arguments:
#   VERSION          - Full version string (e.g., 7.11.0a20251211)
#   AMDGPU_FAMILY    - AMD GPU family (e.g., gfx110X-all, gfx94X-dcgpu)
#   RELEASE_TYPE     - Release type: nightlies (default), prereleases, devreleases
#   TARBALL_URL      - Custom tarball URL (optional, overrides auto-generated URL)
#
# Examples:
#   ./install_rocm_tarball.sh 7.11.0a20251211 gfx110X-all
#   ./install_rocm_tarball.sh 7.11.0a20251211 gfx94X-dcgpu nightly
#   ./install_rocm_tarball.sh 7.11.0a20251211 gfx110X-all nightly https://custom-url/rocm.tar.gz

set -e

# Parse arguments
VERSION="${1:?Error: VERSION is required}"
AMDGPU_FAMILY="${2:?Error: AMDGPU_FAMILY is required}"
RELEASE_TYPE="${3:-nightlies}"
TARBALL_URL="${4:-}"

# Build bucket URL: https://rocm.{RELEASE_TYPE}.amd.com/tarball
# Supported types: nightlies, prereleases, devreleases
BUCKET_URL="https://rocm.${RELEASE_TYPE}.amd.com/tarball"

# Build URL if not provided
if [ -z "$TARBALL_URL" ]; then
    TARBALL_URL="${BUCKET_URL}/therock-dist-linux-${AMDGPU_FAMILY}-${VERSION}.tar.gz"
fi

echo "=============================================="
echo "ROCm Tarball Installation"
echo "=============================================="
echo "Version:         ${VERSION}"
echo "AMDGPU Family:   ${AMDGPU_FAMILY}"
echo "Release Type:    ${RELEASE_TYPE}"
echo "Tarball URL:     ${TARBALL_URL}"
echo "=============================================="

# Download tarball
TARBALL_FILE="/tmp/rocm-tarball.tar.gz"

echo "Downloading tarball..."
wget -q -O "$TARBALL_FILE" "$TARBALL_URL" || {
    echo "Error: Failed to download tarball from $TARBALL_URL"
    exit 1
}

# Verify download
if [ ! -f "$TARBALL_FILE" ] || [ ! -s "$TARBALL_FILE" ]; then
    echo "Error: Downloaded file is empty or does not exist"
    exit 1
fi

# Install directory is fixed to /opt/rocm-{VERSION}
ROCM_INSTALL_DIR="/opt/rocm-${VERSION}"

# Extract tarball to versioned directory
echo "Extracting tarball to ${ROCM_INSTALL_DIR}..."
mkdir -p "$ROCM_INSTALL_DIR"
tar -xzf "$TARBALL_FILE" -C "$ROCM_INSTALL_DIR"

# Clean up downloaded file
rm -f "$TARBALL_FILE"
echo "Tarball extracted and cleaned up"

# Create symlink /opt/rocm -> /opt/rocm-{VERSION} for compatibility
ROCM_SYMLINK="/opt/rocm"
if [ -L "$ROCM_SYMLINK" ]; then
    rm -f "$ROCM_SYMLINK"
fi
if [ ! -e "$ROCM_SYMLINK" ]; then
    ln -s "$ROCM_INSTALL_DIR" "$ROCM_SYMLINK"
    echo "Created symlink: $ROCM_SYMLINK -> $ROCM_INSTALL_DIR"
fi

# Verify installation
echo "Verifying installation..."
if [ -d "$ROCM_INSTALL_DIR/bin" ]; then
    echo "ROCm binaries found in $ROCM_INSTALL_DIR/bin"
    ls -la "$ROCM_INSTALL_DIR/bin" | head -10
else
    echo "Warning: ROCm bin directory not found"
fi

if [ -d "$ROCM_INSTALL_DIR/lib" ]; then
    echo "ROCm libraries found in $ROCM_INSTALL_DIR/lib"
else
    echo "Warning: ROCm lib directory not found"
fi

echo "=============================================="
echo "ROCm installed successfully to $ROCM_INSTALL_DIR"
echo "ROCM_PATH=$ROCM_INSTALL_DIR"
echo "PATH should include: $ROCM_INSTALL_DIR/bin"
echo "=============================================="
