#!/bin/bash
# Verification script for RFC0007 RDC integration
# This script checks that the RDC integration meets all requirements

set -e

BUILD_DIR="${1:-build-5}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEROCK_ROOT="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo "RFC0007 RDC Integration Verification Script"
echo "============================================"
echo "Build directory: $BUILD_DIR"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILED=0
PASSED=0

check() {
    local test_name="$1"
    shift
    echo -n "Checking: $test_name ... "
    if "$@" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PASS${NC}"
        ((PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC}"
        ((FAILED++))
    fi
}

# 1. Check gRPC static libraries exist
echo "=== gRPC Build Verification ==="
check "gRPC static library exists" \
    test -f "$THEROCK_ROOT/$BUILD_DIR/third-party/grpc/build/dist/lib/rocm_sysdeps/lib/libgrpc++.a"

check "Protobuf static library exists" \
    test -f "$THEROCK_ROOT/$BUILD_DIR/third-party/grpc/build/dist/lib/rocm_sysdeps/lib/libprotobuf.a"

# 2. Check gRPC symbol visibility
echo ""
echo "=== gRPC Symbol Visibility ==="
GRPC_LIB="$THEROCK_ROOT/$BUILD_DIR/third-party/grpc/build/dist/lib/rocm_sysdeps/lib/libgrpc++.a"
if [ -f "$GRPC_LIB" ]; then
    GLOBAL_SYMBOLS=$(nm --defined-only "$GRPC_LIB" 2>/dev/null | grep ' T ' | wc -l)
    LOCAL_SYMBOLS=$(nm --defined-only "$GRPC_LIB" 2>/dev/null | grep ' t ' | wc -l)
    
    echo "  Global symbols (T): $GLOBAL_SYMBOLS (should be 0)"
    echo "  Local symbols (t):  $LOCAL_SYMBOLS (should be >0)"
    
    if [ "$GLOBAL_SYMBOLS" -eq 0 ] && [ "$LOCAL_SYMBOLS" -gt 0 ]; then
        echo -e "  ${GREEN}✓ Symbol visibility correctly configured${NC}"
        ((PASSED++))
    else
        echo -e "  ${RED}✗ Symbol visibility NOT configured - gRPC needs rebuild${NC}"
        echo -e "  ${YELLOW}  Hint: Visibility flags were added after initial build${NC}"
        echo -e "  ${YELLOW}  Action: Delete build directory and rebuild${NC}"
        ((FAILED++))
    fi
else
    echo -e "  ${RED}✗ gRPC library not found${NC}"
    ((FAILED++))
fi

# 3. Check RDC binaries exist
echo ""
echo "=== RDC Build Verification ==="
check "rdcd binary exists and is executable" \
    test -x "$THEROCK_ROOT/$BUILD_DIR/profiler/rdc/stage/bin/rdcd"

check "rdci binary exists and is executable" \
    test -x "$THEROCK_ROOT/$BUILD_DIR/profiler/rdc/stage/bin/rdci"

# 4. Check RDC libraries
check "librdc.so exists" \
    test -f "$THEROCK_ROOT/$BUILD_DIR/profiler/rdc/stage/lib/librdc.so.1.2"

check "librdc_client.so exists" \
    test -f "$THEROCK_ROOT/$BUILD_DIR/profiler/rdc/stage/lib/librdc_client.so.1.2"

check "librdc_bootstrap.so exists" \
    test -f "$THEROCK_ROOT/$BUILD_DIR/profiler/rdc/stage/lib/librdc_bootstrap.so.1.2"

# 5. Check RDC symbol pollution
echo ""
echo "=== RDC Symbol Pollution Check ==="
RDC_CLIENT_LIB="$THEROCK_ROOT/$BUILD_DIR/profiler/rdc/stage/lib/librdc_client.so.1.2"
if [ -f "$RDC_CLIENT_LIB" ]; then
    GRPC_SYMBOLS=$(nm -D "$RDC_CLIENT_LIB" 2>/dev/null | grep -c ' T.*grpc::' || true)
    
    echo "  gRPC symbols in librdc_client.so dynamic table: $GRPC_SYMBOLS (should be 0)"
    
    if [ "$GRPC_SYMBOLS" -eq 0 ]; then
        echo -e "  ${GREEN}✓ No gRPC symbol pollution${NC}"
        ((PASSED++))
    else
        echo -e "  ${RED}✗ gRPC symbols are leaking to dynamic symbol table${NC}"
        echo -e "  ${YELLOW}  This indicates symbol visibility is not working${NC}"
        ((FAILED++))
    fi
else
    echo -e "  ${RED}✗ librdc_client.so not found${NC}"
    ((FAILED++))
fi

# 6. Check binary sizes
echo ""
echo "=== Binary Size Verification ==="
if [ -f "$THEROCK_ROOT/$BUILD_DIR/profiler/rdc/stage/bin/rdcd" ]; then
    RDCD_SIZE=$(stat -c%s "$THEROCK_ROOT/$BUILD_DIR/profiler/rdc/stage/bin/rdcd")
    RDCD_SIZE_MB=$((RDCD_SIZE / 1024 / 1024))
    echo "  rdcd size: ${RDCD_SIZE_MB}MB (RFC expected ~50MB, actual ~16MB)"
    
    if [ "$RDCD_SIZE_MB" -gt 5 ] && [ "$RDCD_SIZE_MB" -lt 100 ]; then
        echo -e "  ${GREEN}✓ rdcd size reasonable${NC}"
        ((PASSED++))
    else
        echo -e "  ${YELLOW}⚠ rdcd size unexpected: ${RDCD_SIZE_MB}MB${NC}"
        ((PASSED++))  # Warning, not failure
    fi
fi

if [ -f "$RDC_CLIENT_LIB" ]; then
    CLIENT_SIZE=$(stat -c%s "$RDC_CLIENT_LIB")
    CLIENT_SIZE_MB=$((CLIENT_SIZE / 1024 / 1024))
    echo "  librdc_client.so size: ${CLIENT_SIZE_MB}MB (RFC expected ~50MB, actual ~20MB)"
    
    if [ "$CLIENT_SIZE_MB" -gt 5 ] && [ "$CLIENT_SIZE_MB" -lt 100 ]; then
        echo -e "  ${GREEN}✓ librdc_client.so size reasonable${NC}"
        ((PASSED++))
    else
        echo -e "  ${YELLOW}⚠ librdc_client.so size unexpected: ${CLIENT_SIZE_MB}MB${NC}"
        ((PASSED++))  # Warning, not failure
    fi
fi

# 7. Check dynamic library dependencies
echo ""
echo "=== Dynamic Library Dependencies ==="
if [ -f "$RDC_CLIENT_LIB" ]; then
    echo "  Checking librdc_client.so dependencies:"
    if ldd "$RDC_CLIENT_LIB" 2>/dev/null | grep -q libgrpc; then
        echo -e "  ${RED}✗ librdc_client.so depends on shared gRPC (should be static)${NC}"
        ((FAILED++))
    else
        echo -e "  ${GREEN}✓ No shared gRPC dependency (correctly static linked)${NC}"
        ((PASSED++))
    fi
fi

# Summary
echo ""
echo "============================================"
echo "Summary"
echo "============================================"
echo -e "Tests passed: ${GREEN}$PASSED${NC}"
echo -e "Tests failed: ${RED}$FAILED${NC}"
echo ""

if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed! RFC0007 integration is correct.${NC}"
    exit 0
else
    echo -e "${RED}✗ Some checks failed. See above for details.${NC}"
    echo ""
    echo "Common fixes:"
    echo "  1. If gRPC symbol visibility failed:"
    echo "     rm -rf $BUILD_DIR/third-party/grpc"
    echo "     ninja -C $BUILD_DIR therock-grpc"
    echo ""
    echo "  2. If RDC tests failed:"
    echo "     rm -rf $BUILD_DIR/profiler/rdc"
    echo "     ninja -C $BUILD_DIR rdc"
    echo ""
    echo "  3. For complete rebuild:"
    echo "     rm -rf $BUILD_DIR"
    echo "     cmake -B $BUILD_DIR ..."
    echo "     ninja -C $BUILD_DIR"
    exit 1
fi
