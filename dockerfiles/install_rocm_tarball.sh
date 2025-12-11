#!/bin/bash
# install_rocm_tarball.sh
#
# Downloads and installs ROCm from a nightly tarball.
# Architecture supports future extension to other release types and install methods.
#
# The tarball is extracted to a versioned directory based on ROCM_VERSION.
# For example, with version 7.11.0a20251209:
#   - Install directory: /opt/rocm-7.11.0a20251209/
#   - Symlink: /opt/rocm -> /opt/rocm-7.11.0a20251209
#
# Usage:
#   ./install_rocm_tarball.sh <ROCM_VERSION> <AMDGPU_FAMILY> [INSTALL_PREFIX] [RELEASE_TYPE] [TARBALL_URL]
#
# Arguments:
#   ROCM_VERSION     - ROCm version (e.g., 6.5.0rc20250610)
#   AMDGPU_FAMILY    - AMD GPU family (e.g., gfx110X-all, gfx94X-dcgpu)
#   INSTALL_PREFIX   - Installation prefix directory (default: /opt)
#   RELEASE_TYPE     - Release type (default: nightly). Reserved for future extension.
#   TARBALL_URL      - Custom tarball URL (optional, overrides default S3 URL)
#
# Examples:
#   ./install_rocm_tarball.sh 6.5.0rc20250610 gfx110X-all
#   ./install_rocm_tarball.sh 6.5.0rc20250610 gfx94X-dcgpu /opt
#   ./install_rocm_tarball.sh 6.5.0rc20250610 gfx110X-all /opt nightly https://custom-url/rocm.tar.gz

set -e

# Parse arguments
ROCM_VERSION="${1:?Error: ROCM_VERSION is required}"
AMDGPU_FAMILY="${2:?Error: AMDGPU_FAMILY is required}"
INSTALL_PREFIX="${3:-/opt}"
RELEASE_TYPE="${4:-nightly}"
TARBALL_URL="${5:-}"

# Build S3 bucket URL based on release type
# Format: https://therock-{RELEASE_TYPE}-tarball.s3.amazonaws.com
# Currently only nightly is supported; architecture allows future extension
S3_BUCKET="https://therock-${RELEASE_TYPE}-tarball.s3.amazonaws.com"

# Build default URL if not provided
if [ -z "$TARBALL_URL" ]; then
    TARBALL_URL="${S3_BUCKET}/therock-dist-linux-${AMDGPU_FAMILY}-${ROCM_VERSION}.tar.gz"
fi

echo "=============================================="
echo "ROCm Tarball Installation"
echo "=============================================="
echo "ROCm Version:    ${ROCM_VERSION}"
echo "AMDGPU Family:   ${AMDGPU_FAMILY}"
echo "Install Prefix:  ${INSTALL_PREFIX}"
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

# Build versioned install directory path (e.g., /opt/rocm-7.11.0a20251209)
ROCM_INSTALL_DIR="${INSTALL_PREFIX}/rocm-${ROCM_VERSION}"

# Extract tarball to versioned directory
echo "Extracting tarball to ${ROCM_INSTALL_DIR}..."
mkdir -p "$ROCM_INSTALL_DIR"
tar -xzf "$TARBALL_FILE" -C "$ROCM_INSTALL_DIR"

# Clean up downloaded file
rm -f "$TARBALL_FILE"
echo "Tarball extracted and cleaned up"

# Create symlink /opt/rocm -> /opt/rocm-X.Y.Z for compatibility
ROCM_SYMLINK="${INSTALL_PREFIX}/rocm"
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
echo "ROCM_HOME=$ROCM_INSTALL_DIR"
echo "PATH should include: $ROCM_INSTALL_DIR/bin"
echo "=============================================="
