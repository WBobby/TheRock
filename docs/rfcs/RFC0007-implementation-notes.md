# RFC0007 Implementation Notes

This document tracks the implementation status and deviations from [RFC0007: RDC TheRock Integration with Static gRPC](RFC0007-rdc-therock-integration.md).

## Implementation Status

**Status:** ✅ Fully Implemented and RFC Compliant  
**Integration Date:** November 2024  
**Latest Update:** November 2025 (RFC compliance restructuring)  
**Key Milestones:**
- November 2024: Initial RDC integration with static gRPC
- November 2024: Symbol visibility and testing enhancements
- November 2025: Directory restructuring to dctools/ (RFC compliance)
- November 2025: Enhanced static linking configuration and validation

## Deviations from Original RFC

### 1. gRPC Version Upgrade

**RFC Specification:** v1.67.1  
**Actual Implementation:** v1.76.0

**Reason:** Better compatibility with the current LLVM/Clang compiler version used in TheRock. The v1.76.0 release includes important fixes and improvements for modern compiler toolchains.

**Impact:** None. The gRPC v1.76.0 API is backward compatible with v1.67.1. All RFC goals and requirements are met.

### 2. Binary Sizes (Better Than Expected)

**RFC Predictions vs. Actual:**

| Component | RFC Prediction | Actual Size | Improvement |
|-----------|----------------|-------------|-------------|
| rdcd | ~50MB | 16MB | 68% smaller |
| rdci | ~50MB | 323KB | 99% smaller |
| librdc_client.so | ~50MB | 20MB | 60% smaller |
| librdc_bootstrap.so | ~200KB | 131KB | 34% smaller |
| librdc.so | ~2MB | 610KB | 69% smaller |

**Total:** ~36MB for all standalone components (RFC predicted ~150MB)

**Reason:** The RFC's size estimates were conservative. Actual implementation benefits from:
- Better linker optimization (LTO/dead code elimination)
- Accurate analysis of what symbols are actually needed
- Efficient static linking with hidden visibility

**Impact:** Positive! Distribution is more efficient than planned.

### 3. Directory Structure

**RFC Specification:** `dctools/` directory  
**Current Implementation:** `dctools/` directory ✅

**Status:** Fully compliant with RFC0007 as of latest restructuring.

**Implementation:**
```
dctools/
├── CMakeLists.txt      # RDC subproject declaration
└── artifact-rdc.toml   # Artifact descriptor using portable-rdc/ structure
```

**Distribution Structure:**
```
portable-rdc/
├── bin/           # rdcd, rdci executables
├── lib/           # librdc.so, librdc_client.so, librdc_bootstrap.so
│   └── rdc/       # Plugin modules (librdc_rocr.so, etc.)
├── etc/           # Configuration files
└── share/         # Documentation and runtime data
```

**Impact:** Better organizational alignment with AMD's system tools structure.

### 4. Symbol Visibility Implementation Timeline

**RFC Requirement:** Symbol visibility controls (`CMAKE_CXX_VISIBILITY_PRESET=hidden`)  
**Initial Implementation:** Not included  
**Current Status:** ✅ Implemented (November 2024)

**Reason:** Initial implementation focused on getting the build working. Symbol visibility was added as a quality improvement in a follow-up commit.

**Impact:** Now fully compliant with RFC requirements. gRPC symbols are hidden to prevent ODR violations.

## Architecture Verification

### Static Linking Confirmation

```bash
# Verify no dynamic gRPC dependencies
$ readelf -d build-4/dist/rocm/lib/librdc_client.so.1.2 | grep NEEDED
# Output shows only: librdc_bootstrap, pthread, rt, dl, zlib, stdc++, m, gcc_s, c
# ✅ No libgrpc++.so or libprotobuf.so

# Verify gRPC symbols are embedded
$ nm --dynamic build-4/dist/rocm/lib/librdc_client.so.1.2 | grep -c grpc
# Output: ~2000 gRPC symbols present
# ✅ gRPC is statically linked

# Verify no gRPC shared libraries installed
$ ls build-4/dist/rocm/lib/rdc/grpc/
# ls: cannot access: No such file or directory
# ✅ No separate gRPC installation
```

### Binary Size Verification

```bash
$ ls -lh build-4/dist/rocm/bin/rdcd build-4/dist/rocm/bin/rdci
-rwxr-xr-x 16M rdcd
-rwxr-xr-x 323K rdci

$ ls -lh build-4/dist/rocm/lib/librdc*.so.1.2
131K librdc_bootstrap.so.1.2
20M librdc_client.so.1.2
610K librdc.so.1.2
```

## Success Metrics (RFC Goals)

### Primary Goals

- ✅ **Portable, distribution-neutral RDC builds** - No system gRPC dependencies
- ✅ **Static gRPC linking** - All gRPC code embedded in binaries
- ✅ **Both build modes supported** - Embedded (librdc.so) and Standalone (rdcd/rdci)
- ✅ **Symbol isolation** - Hidden visibility prevents pollution
- ✅ **BoringSSL integration** - Statically linked from gRPC submodule

### Secondary Goals

- ✅ **Artifact packaging** - Proper component separation (dev, lib, run, doc, dbg)
- ✅ **CMake package provision** - Downstream projects can find_package(rdc)
- ✅ **Validation tests** - Static library and symbol visibility checks
- ✅ **Optional modules** - librdc_rocr.so and librdc_rocp.so built successfully

### Non-Goals (As Expected)

- ❌ **Python wheel packaging** - Deferred to future work (as planned)
- ❌ **Windows/macOS support** - Linux x86_64 only (as planned)
- ❌ **System package replacement** - System packages still maintained (as planned)

## Testing Strategy

### Build-Time vs. Runtime Tests

**Build-Time Tests (Included):**
- ✅ Static library validation (`validate_static_library.sh`)
- ✅ Symbol pollution prevention (RDC shared libs) - **The critical test**
- ✅ Binary existence and file structure checks
- ⚠️ Note: We do NOT test for zero global symbols in gRPC static libraries
  - Static libraries must export public API symbols (T) for linking
  - The real validation is that final shared libraries don't leak gRPC symbols

**Runtime Tests (NOT Included in Build):**
- ❌ rdcd/rdci execution tests - Require GPU hardware
- ❌ RDC functionality tests - Need full ROCm stack
- ❌ Client-server communication - Needs daemon running

**Rationale:**
Build machines may not have:
1. GPU hardware (rdcd/rdci need GPU access)
2. Proper runtime environment (LD_LIBRARY_PATH configuration)
3. ROCm kernel drivers loaded

Runtime integration tests should be performed separately in GPU-enabled test environments with proper ROCm installation.

## Technical Decisions

### 1. BoringSSL vs. OpenSSL

**Decision:** Use BoringSSL bundled with gRPC  
**Rationale:**
- Self-contained, no external SSL dependency
- Designed for static linking by Google
- ISC license compatible with ROCm
- Symbols automatically hidden via visibility controls

**Alternative Considered:** Add OpenSSL to TheRock sysdeps  
**Rejected Because:** Significant maintenance burden for minimal benefit. RDC commonly runs in insecure mode (`-u` flag) for development/testing.

### 2. gRPC Location: third-party vs. sysdeps

**Decision:** Place gRPC in `third-party/` not `sysdeps/`  
**Rationale:**
- gRPC is statically linked (not a runtime sysdep)
- No SONAME management needed
- Clearer separation: sysdeps = runtime deps, third-party = build deps

### 3. Symbol Visibility Strategy

**Decision:** Build gRPC with `-DCMAKE_CXX_VISIBILITY_PRESET=hidden`  
**Rationale:**
- Prevents ODR violations if another component uses gRPC/protobuf
- Reduces dynamic symbol table size in librdc_client.so
- Industry best practice for static linking

## Known Limitations

1. **gRPC version locked to v1.76.0** - Upgrading requires careful testing
2. **Linux x86_64 only** - No ARM64 support yet (not in RFC scope)
3. **No shared gRPC** - If other components need gRPC, must coordinate carefully
4. **Limited build-time testing** - Runtime tests (rdcd/rdci execution) require GPU hardware and are not suitable for build machines

## Future Work

### Short-term (Next 6 months)

- Monitor gRPC security updates
- Add ARM64 support if needed
- Improve validation test coverage

### Long-term (12+ months)

- Consider Python wheel packaging for RDC
- Evaluate if other ROCm components need gRPC
- Assess gRPC version upgrade path

## References

- [RFC0007: RDC TheRock Integration](RFC0007-rdc-therock-integration.md)
- [Dependencies Documentation](../development/dependencies.md#grpc)
- [RDC Source Repository](https://github.com/ROCm/rdc)
- [gRPC Build Documentation](https://github.com/grpc/grpc/blob/v1.76.0/BUILDING.md)

## Revision History

- 2025-11-12: Initial implementation notes documenting actual vs. RFC
- 2024-11-10: RDC integration completed (commit ef547e7b)
- 2024-11-09: gRPC moved to third-party (commit 0c96c0e3)

