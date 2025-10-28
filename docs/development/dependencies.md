# Dependencies

The ROCm projects have a number of dependencies. Typically those that escape
any specific library and are generally available as part of an OS distribution
are the concern of TheRock. In these cases, TheRock prefers to build them
all from source in such that:

- They are installed into the `lib/rocm_sysdeps` prefix.
- All ROCm libraries can find them by adding an appropriate relative RPATH.
- For symbol-versioned libraries, all symbols will be prefixed with
  `AMDROCM_SYSDEPS_1.0_`; whereas for non-versioned libraries, they will be
  built to version all symbols with `AMDROCM_SYSDEPS_1.0`.
- SONAMEs and semantic version symlink redirects are altered so that a single
  SONAME shared library with a prefix of `rocm_sysdeps_` is available to
  link against, using a `lib{originalname}.so` as a dev symlink.
- Any PackageConfig descriptors are altered to be location independent.
- PackageConfig and CMake `find_package` config files are advertised (being
  created as necessary) so that package resolution happens the same as if
  they were OS installed.

In order for this setup to work, a number of conventions need to be followed
project wide:

- Sub-projects should declare their use of a sysdep by including one or more of
  the global variables in their `RUNTIME_DEPS` (these will be empty if
  bundling is not enabled or supported for the target OS):
  - `THEROCK_BUNDLED_BZIP2`
  - `THEROCK_BUNDLED_ELFUTILS`
  - `THEROCK_BUNDLED_GRPC`
  - `THEROCK_BUNDLED_LIBCAP`
  - `THEROCK_BUNDLED_LIBDRM`
  - `THEROCK_BUNDLED_LIBLZMA`
  - `THEROCK_BUNDLED_NUMACTL`
  - `THEROCK_BUNDLED_SQLITE3`
  - `THEROCK_BUNDLED_ZLIB`
  - `THEROCK_BUNDLED_ZSTD`
- Sub-projects must arrange for any libraries that depend on these to add the
  RPATH `lib/rocm_sysdeps/lib`.
- All projects should use the same package resolution technique (see below).

## Canonical Way to Depend

Per usual with CMake and the proliferation of operating systems, there is no
one true way to depend on a library. In general, if common distributions make
a library available via `find_package(foo CONFIG)`, we prefer that mechanism
be used consistently.

Implementation notes for each library is below:

## BZip2

- Canonical method: `find_package(BZip2)`
- Import library: `BZip2::BZip2`
- Alternatives: None (some OS vendors will provide alternatives but the source
  distribution of bzip2 has no opinion)

## ELFUTILS

Supported sub-libraries: `libelf`, `libdw`.

### libelf

- Canonical method: `find_package(LibElf)`
- Import library: `elf::elf`
- Alternatives: `pkg_check_modules(ELF libelf)`

### libdw

- Canonical method: `find_package(libdw)`
- Import library: `libdw::libdw`
- Alternatives: `pkg_check_modules(DW libdw)`

## gRPC

gRPC is a high-performance RPC framework used exclusively by RDC (ROCm Data 
Center Tool) for its standalone mode components (rdcd daemon and rdci CLI).

**Note:** gRPC is built as **static libraries** and linked into RDC binaries.
It is integrated as a third-party dependency, not a traditional sysdep, but
follows similar bundling patterns.

**Organization:** RDC is organized under `dctools/` (datacenter tools) directory,
separate from profiling tools. See RFC0007 for rationale.

- **Integration:** Third-party static libraries under `third-party/grpc/`
- **Version:** v1.67.1 (as specified in RFC0007)
  - **Rationale:** This is the tested and validated version for RDC integration
  - **Symbol Visibility:** Statically linked with comprehensive visibility controls to prevent symbol pollution
- **Build Configuration:** Static-only build with symbol visibility controls
  - `-DBUILD_SHARED_LIBS=OFF`
  - `-DgRPC_BUILD_SHARED_LIBS=OFF`
  - `-DgRPC_PREFER_STATIC_LIBS=ON`
  - `-Dprotobuf_BUILD_SHARED_LIBS=OFF`
  - `-DCMAKE_CXX_VISIBILITY_PRESET=hidden`
  - `-DCMAKE_C_VISIBILITY_PRESET=hidden`
  - `-DCMAKE_VISIBILITY_INLINES_HIDDEN=ON`
  - `-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--exclude-libs,ALL`
  - `-DCMAKE_EXE_LINKER_FLAGS=-Wl,--exclude-libs,ALL`
  - `-DCMAKE_MODULE_LINKER_FLAGS=-Wl,--exclude-libs,ALL`
- **SSL Provider:** BoringSSL (built from gRPC submodule, statically linked)
- **Linking:** Static linking into RDC binaries (rdcd, rdci, librdc_client.so)
- **Canonical method:** `find_package(gRPC CONFIG REQUIRED)`
- **Import libraries:** 
  - `gRPC::grpc++` - C++ gRPC library
  - `gRPC::grpc` - Core gRPC C library
  - `protobuf::libprotobuf` - Protocol buffers runtime
  - `gRPC::grpc_cpp_plugin` - Code generator tool
  - `protobuf::protoc` - Protocol buffers compiler
- **Bundled variable:** `THEROCK_BUNDLED_GRPC` (Linux only)
- **Alternatives:** None (required for RDC standalone mode only)

**Important:** gRPC symbols are hidden via visibility controls to prevent ODR
violations. Do not use gRPC in other TheRock projects without coordination, as
it may conflict with the statically-linked instance in RDC.

**Dependencies:** gRPC bundles and statically links the following:
- Abseil (abseil-cpp) - C++ common libraries
- Protocol Buffers (protobuf) - Serialization
- RE2 - Regular expression library
- c-ares - Asynchronous DNS resolver
- BoringSSL - SSL/TLS library (Google's OpenSSL fork)

## libcap

Linux capabilities library, used by RDC for privilege management.

- **Canonical method:** `find_library(LIB_CAP NAMES cap REQUIRED)`
- **Import library:** Not provided (use ${LIB_CAP} variable)
- **Bundled variable:** `THEROCK_BUNDLED_LIBCAP` (Linux only)
- **Alternatives:** System installation via libcap-dev/libcap-devel packages

## libdrm

Supported sub-libraries: `libdrm`, `libdrm_amdgpu`

### libdrm

- Canonical method: `pkg_check_modules(DRM REQUIRED IMPORTED_TARGET libdrm)`
- Import library: `PkgConfig::DRM`
- Vars: `DRM_INCLUDE_DIRS`

### libdrm_amdgpu

- Canonical method: `pkg_check_modules(DRM_AMDGPU REQUIRED IMPORTED_TARGET libdrm_amdgpu)`
- Import library: `PkgConfig::DRM_AMDGPU`
- Vars: `DRM_AMDGPU_INCLUDE_DIRS`

## liblzma

- Canonical method: `find_package(LibLZMA)`
- Import library: `LibLZMA::LibLZMA`
- Alternatives: `pkg_check_modules(LZMA liblzma)`

### numactl

Provides the `libnuma` library. Tools are not included in bundled sysdeps.

- Canonical method: `find_package(NUMA)`
- Import library: `numa::numa`
- Vars: `NUMA_INCLUDE_DIRS`, `NUMA_INCLUDE_LIBRARIES` (can be used to avoid
  a hard-coded dep on `numa::numa`, which seems to vary across systems)
- Alternatives: `pkg_check_modules(NUMA numa)`

## sqlite3

- Canonical method: `find_package(SQLite3)`
- Import library: `SQLite::SQLite3`
- Alternatives: none

## zlib

- Canonical method: `find_package(ZLIB)`
- Import library: `ZLIB::ZLIB`
- Alternatives: `pkg_check_modules(ZLIB zlib)`

## zstd

- Canonical method: `find_package(zstd)`
- Import library: `zstd::libzstd_shared`
- Alternatives: `pkg_check_modules(ZSTD libzstd)`
