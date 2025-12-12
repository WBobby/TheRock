# rocm-runtime.Dockerfile
#
# ROCm Runtime Docker Image Builder
# Supports multiple Linux distributions through a single Dockerfile.
#
# Supported base images:
#   - ubuntu:24.04
#   - almalinux:8
#   - mcr.microsoft.com/azurelinux/base/core:3.0
#
# Build arguments:
#   BASE_IMAGE       - Base Docker image (default: ubuntu:24.04)
#   VERSION          - Full version string (e.g., 7.11.0a20251211)
#   AMDGPU_FAMILY    - AMD GPU family (e.g., gfx110X-all, gfx94X-dcgpu)
#   RELEASE_TYPE     - Release type (default: nightlies). Options: prereleases, devreleases
#
# Build examples:
#
#   # Ubuntu 24.04 + gfx110X (nightly)
#   docker build \
#     --build-arg BASE_IMAGE=ubuntu:24.04 \
#     --build-arg VERSION=7.11.0a20251211 \
#     --build-arg AMDGPU_FAMILY=gfx110X-all \
#     -f dockerfiles/rocm-runtime.Dockerfile \
#     -t rocm-nightly:ubuntu24.04-gfx110X \
#     dockerfiles/
#
#   # AlmaLinux 8 + gfx94X (nightly)
#   docker build --network=host \
#     --build-arg BASE_IMAGE=almalinux:8 \
#     --build-arg VERSION=7.11.0a20251211 \
#     --build-arg AMDGPU_FAMILY=gfx94X-dcgpu \
#     -f dockerfiles/rocm-runtime.Dockerfile \
#     -t rocm-nightly:almalinux8-gfx94X \
#     dockerfiles/
#
#   # Azure Linux 3 + gfx120X (nightly)
#   docker build \
#     --build-arg BASE_IMAGE=mcr.microsoft.com/azurelinux/base/core:3.0 \
#     --build-arg VERSION=7.11.0a20251211 \
#     --build-arg AMDGPU_FAMILY=gfx120X-all \
#     -f dockerfiles/rocm-runtime.Dockerfile \
#     -t rocm-nightly:azurelinux3-gfx120X \
#     dockerfiles/
#
# Run example:
#   docker run --rm -it --device=/dev/kfd --device=/dev/dri \
#     --security-opt seccomp=unconfined \
#     rocm-nightly:ubuntu24.04-gfx110X rocminfo

# Base image selection
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

LABEL maintainer="TheRock Team"
LABEL description="ROCm runtime image built from TheRock project"
LABEL org.opencontainers.image.source="https://github.com/ROCm/TheRock"

# ROCm configuration arguments
ARG VERSION
ARG AMDGPU_FAMILY
ARG RELEASE_TYPE=nightlies

# Copy installation scripts
COPY install_rocm_deps.sh /tmp/
COPY install_rocm_tarball.sh /tmp/

# Install system dependencies
# The script auto-detects the distribution and uses the appropriate package manager
RUN chmod +x /tmp/install_rocm_deps.sh && \
    /tmp/install_rocm_deps.sh

# Install ROCm from tarball
# Tarball extracts to /opt/rocm-{VERSION}/, with symlink /opt/rocm -> /opt/rocm-{VERSION}
RUN chmod +x /tmp/install_rocm_tarball.sh && \
    /tmp/install_rocm_tarball.sh \
        "${VERSION}" \
        "${AMDGPU_FAMILY}" \
        "${RELEASE_TYPE}" && \
    rm -f /tmp/install_rocm_deps.sh /tmp/install_rocm_tarball.sh

# Configure environment variables
ENV ROCM_PATH=/opt/rocm
ENV PATH="/opt/rocm/bin:${PATH}"
