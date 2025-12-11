# rocm_nightly.Dockerfile
#
# Unified Nightly ROCm Docker Image
# Supports multiple Linux distributions through a single Dockerfile.
#
# Supported base images:
#   - ubuntu:22.04
#   - ubuntu:24.04
#   - almalinux:8
#   - mcr.microsoft.com/azurelinux/base/core:3.0
#
# Build arguments:
#   BASE_IMAGE       - Base Docker image (default: ubuntu:24.04)
#   ROCM_VERSION     - ROCm nightly version (e.g., 6.5.0rc20250610)
#   AMDGPU_FAMILY    - AMD GPU family (e.g., gfx110X-all, gfx94X-dcgpu)
#   INSTALL_PREFIX   - Installation prefix (default: /opt). ROCm will be at /opt/rocm-X.Y/
#   RELEASE_TYPE     - Release type (default: nightly). Reserved for future extension.
#   TARBALL_URL      - Custom tarball URL (optional, overrides S3 URL)
#
# Build examples:
#
#   # Ubuntu 24.04 + gfx110X
#   docker build \
#     --build-arg BASE_IMAGE=ubuntu:24.04 \
#     --build-arg ROCM_VERSION=6.5.0rc20250610 \
#     --build-arg AMDGPU_FAMILY=gfx110X-all \
#     -f dockerfiles/rocm_nightly.Dockerfile \
#     -t rocm-nightly:ubuntu24.04-gfx110X \
#     dockerfiles/
#
#   # AlmaLinux 8 + gfx94X
#   docker build \
#     --build-arg BASE_IMAGE=almalinux:8 \
#     --build-arg ROCM_VERSION=6.5.0rc20250610 \
#     --build-arg AMDGPU_FAMILY=gfx94X-dcgpu \
#     -f dockerfiles/rocm_nightly.Dockerfile \
#     -t rocm-nightly:almalinux8-gfx94X \
#     dockerfiles/
#
#   # Azure Linux 3 + gfx120X
#   docker build \
#     --build-arg BASE_IMAGE=mcr.microsoft.com/azurelinux/base/core:3.0 \
#     --build-arg ROCM_VERSION=6.5.0rc20250610 \
#     --build-arg AMDGPU_FAMILY=gfx120X-all \
#     -f dockerfiles/rocm_nightly.Dockerfile \
#     -t rocm-nightly:azurelinux3-gfx120X \
#     dockerfiles/
#
# Run example:
#   docker run --rm -it --device=/dev/kfd --device=/dev/dri \
#     --group-add video --group-add render \
#     rocm-nightly:ubuntu24.04-gfx110X rocminfo

# Base image selection
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

LABEL maintainer="TheRock Team"
LABEL description="Nightly ROCm runtime image built from TheRock project"
LABEL org.opencontainers.image.source="https://github.com/ROCm/TheRock"

# ROCm configuration arguments
ARG ROCM_VERSION
ARG AMDGPU_FAMILY
ARG INSTALL_PREFIX=/opt
ARG RELEASE_TYPE=nightly
ARG TARBALL_URL=""

# Copy installation scripts
COPY install_rocm_deps.sh /tmp/
COPY install_rocm_tarball.sh /tmp/

# Install system dependencies
# The script auto-detects the distribution and uses the appropriate package manager
RUN chmod +x /tmp/install_rocm_deps.sh && \
    /tmp/install_rocm_deps.sh

# Install ROCm from nightly tarball
# Tarball extracts to /opt/rocm-X.Y/, with symlink /opt/rocm -> /opt/rocm-X.Y
RUN chmod +x /tmp/install_rocm_tarball.sh && \
    /tmp/install_rocm_tarball.sh \
        "${ROCM_VERSION}" \
        "${AMDGPU_FAMILY}" \
        "${INSTALL_PREFIX}" \
        "${RELEASE_TYPE}" \
        "${TARBALL_URL}" && \
    rm -f /tmp/install_rocm_deps.sh /tmp/install_rocm_tarball.sh

# Configure environment variables
ENV ROCM_PATH=/opt/rocm
ENV PATH="/opt/rocm/bin:${PATH}"
