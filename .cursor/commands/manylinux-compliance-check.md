# ManyLinux 构建合规性检查 - gRPC 和 RDC

## 📋 检查目标

根据 `docs/design/manylinux_builds.md` 的要求，检查 gRPC 和 RDC 是否满足 manylinux 构建规范。

---

## 📖 ManyLinux 构建要求总结

根据文档，manylinux 构建的三个核心要素：

### 1. 使用 ManyLinux Docker 镜像构建
- 基于 AlmaLinux（glibc 2.28）
- 使用 gcc-toolset
- **约束**：不安装任何 `*-devel` 包（除了 gcc-toolset）

### 2. 使用 `-DTHEROCK_BUNDLE_SYSDEPS=ON`
- 配置构建系统生产 vendored 版本的依赖
- 避免运行时在目标系统上解析依赖

### 3. 所有 Vendored 依赖的处理规范

**安装位置**：
- 所有 bundled sysdeps 必须安装到 `lib/rocm_sysdeps`
- RPATH 配置为使用 origin-relative 路径

**库文件修改**：
- ✅ 统一目录：`lib*/` → `lib/`
- ✅ 可重定位：packaging 文件设置为 relocatable
- ✅ 符号版本：使用 `AMDROCM_SYSDEPS_1.0` 版本
- ✅ SONAME 前缀：重写为 `rocm_sysdeps_` 前缀以避免冲突

**兼容性检查**：
- ✅ 不依赖 glibc 之外的系统库
- ✅ 使用 `ldd` 或最小 docker 镜像验证

---

## ✅ gRPC 合规性检查

### 1. 安装位置 ✅

```bash
$ third-party/sysdeps/linux/grpc/CMakeLists.txt:
INSTALL_DESTINATION
  lib/rocm_sysdeps
INTERFACE_INCLUDE_DIRS
  lib/rocm_sysdeps/include
INTERFACE_LINK_DIRS
  lib/rocm_sysdeps/lib
INTERFACE_INSTALL_RPATH_DIRS
  lib/rocm_sysdeps/lib
INTERFACE_PKG_CONFIG_DIRS
  lib/rocm_sysdeps/lib/pkgconfig
```

**✅ 合规**：gRPC 正确安装到 `lib/rocm_sysdeps/` 目录。

---

### 2. SONAME 重写 ✅

**patch_install.sh 实现**：
```bash
# Find all .so files and patch them
find "$PREFIX/lib" -name "*.so*" -type f | while read -r sofile; do
  if file "$sofile" | grep -q "ELF.*shared object"; then
    "$Python3_EXECUTABLE" "$THEROCK_SOURCE_DIR/build_tools/patch_linux_so.py" \
      --patchelf "${PATCHELF}" --add-prefix rocm_sysdeps_ \
      "$sofile"
  fi
done
```

**验证结果**：
```bash
$ ls build-3/third-party/sysdeps/linux/grpc/build/dist/lib/rocm_sysdeps/lib/*.so*
librocm_sysdeps_z.so.1 -> librocm_sysdeps_z.so.1.3.1  # ✅ 有前缀
librocm_sysdeps_z.so.1.3.1                              # ✅ 有前缀
libz.so -> librocm_sysdeps_z.so.1                       # ✅ 兼容性符号链接
```

**✅ 合规**：共享库的 SONAME 正确添加了 `rocm_sysdeps_` 前缀。

---

### 3. 可重定位配置 ✅

**patch_install.sh 处理 pkgconfig**：
```bash
# Update .pc files to use relative paths
for pcfile in "$PREFIX/lib/pkgconfig"/*.pc; do
  sed -i -E 's|^prefix=.+|prefix=${pcfiledir}/../..|' "$pcfile"
  sed -i -E 's|^exec_prefix=.+|exec_prefix=${prefix}|' "$pcfile"
  sed -i -E 's|^libdir=.+|libdir=${prefix}/lib|' "$pcfile"
  sed -i -E 's|^includedir=.+|includedir=${prefix}/include|' "$pcfile"
done
```

**patch_install.sh 处理 CMake 配置**：
```bash
# Update gRPC CMake configs
sed -i 's|INTERFACE_INCLUDE_DIRECTORIES "[^"]*include|INTERFACE_INCLUDE_DIRECTORIES "${_IMPORT_PREFIX}/include|g'
sed -i 's|IMPORTED_LOCATION "[^"]*lib/\([^"]*\)"|IMPORTED_LOCATION "${_IMPORT_PREFIX}/lib/\1"|g'
```

**✅ 合规**：pkgconfig 和 CMake 配置文件使用相对路径，支持重定位。

---

### 4. RPATH 设置 ✅

**CMakeLists.txt 中的 RPATH 配置**：
```cmake
# Set RPATH for installed libraries and executables
# $ORIGIN for libs, $ORIGIN/../lib for bins (protoc, grpc_cpp_plugin)
"-DCMAKE_INSTALL_RPATH=\$ORIGIN:\$ORIGIN/../lib"
"-DCMAKE_BUILD_RPATH_USE_ORIGIN=ON"
```

**✅ 合规**：使用 origin-relative RPATH，支持可重定位安装。

---

### 5. 静态链接策略 ✅✅

**关键发现**：gRPC 主要以**静态库**形式提供！

```bash
$ ls build-3/third-party/sysdeps/linux/grpc/build/dist/lib/rocm_sysdeps/lib/*.a
libgrpc++.a           # 2.3M - 主 gRPC C++ 库
libgrpc.a             # 49M  - gRPC 核心
libprotobuf.a         # 6.7M - protobuf 运行时
libabsl_*.a           # 大量 abseil 静态库
libupb_*.a            # upb 静态库
libre2.a              # RE2 正则表达式
libcares.a            # c-ares DNS
libssl.a / libcrypto.a # OpenSSL
```

**只有 zlib 提供共享库**：
```bash
$ ls build-3/third-party/sysdeps/linux/grpc/build/dist/lib/rocm_sysdeps/lib/*.so*
librocm_sysdeps_z.so.1.3.1  # zlib 共享库（带正确前缀）
```

**✅✅ 最佳实践**：
- gRPC 核心库使用静态链接，避免运行时依赖冲突
- 只有 zlib 使用共享库（因为多个 DSO 可能共享）
- 符合文档建议："When it makes sense, we prefer to pull dependencies in as static libraries"

---

### 6. 构建时工具 ✅

**工具安装位置**：
```bash
$ ls build-3/profiler/dist/lib/rocm_sysdeps/bin/
protoc               # protobuf 编译器
protoc-31.1.0        # 带版本号
grpc_cpp_plugin      # gRPC C++ 插件
```

**✅ 合规**：
- 工具正确安装到 `rocm_sysdeps/bin/`
- 通过 RPATH 可以找到依赖的 zlib 库
- 工具在构建时和运行时都可用

---

### 7. 符号版本（Symbol Versioning）✅

**预期**：文档要求使用 `AMDROCM_SYSDEPS_1.0` 符号版本。

**实际检查（zlib 共享库）**：
```bash
$ objdump -p build-3/.../lib/librocm_sysdeps_z.so.1.3.1 | grep "Version definitions"
Version definitions:
1 0x01 0x0f1060c1 librocm_sysdeps_z.so.1
2 0x00 0x0f0ab8d0 AMDROCM_SYSDEPS_1.0  ✅

$ readelf -d build-3/.../lib/librocm_sysdeps_z.so.1.3.1 | grep SONAME
 0x000000000000000e (SONAME)  Library soname: [librocm_sysdeps_z.so.1]  ✅
```

**✅ 合规**：
- zlib 共享库正确使用了 `AMDROCM_SYSDEPS_1.0` 符号版本
- SONAME 正确设置为 `librocm_sysdeps_z.so.1`（带前缀）
- gRPC 主要以静态库形式提供，不需要符号版本

---

## ✅ RDC 合规性检查

### 1. 作为 Vendored 依赖使用 gRPC ✅

**RDC 配置**：
```cmake
RUNTIME_DEPS
  ROCR-Runtime
  amdsmi
  rocprofiler-sdk
  ${THEROCK_BUNDLED_LIBCAP}
  ${THEROCK_BUNDLED_ZLIB}
  ${THEROCK_BUNDLED_GRPC}  # ✅ 使用 bundled gRPC
```

**✅ 合规**：RDC 正确声明 gRPC 为 RUNTIME_DEPS。

---

### 2. 依赖解析通过 find_package ✅

**当前实现（激进方案）**：
```cmake
# RDC depends on gRPC for both runtime (libgrpc++.so) and build-time (protoc, grpc_cpp_plugin).
# RUNTIME_DEPS includes ${THEROCK_BUNDLED_GRPC} which ensures:
# 1. gRPC is built before RDC
# 2. CMAKE_PREFIX_PATH includes gRPC's stage directory
# 3. find_package(gRPC) and find_package(protobuf) will find the config files
# 4. gRPCConfig.cmake exports tool targets (gRPC::grpc_cpp_plugin, protobuf::protoc)
#
# No hardcoded paths needed - all dependencies are resolved via CMake's standard mechanisms.

therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    -DBUILD_STANDALONE=ON
    # ... 其他参数，无硬编码路径
  RUNTIME_DEPS
    ${THEROCK_BUNDLED_GRPC}
)
```

**✅ 合规**：
- 完全依赖 `CMAKE_PREFIX_PATH` 和 `find_package()`
- 无硬编码路径
- 符合 TheRock 依赖管理最佳实践

---

### 3. RDC 不重复安装 gRPC ✅

**验证结果**：
```bash
# 检查 RDC 是否重复安装 gRPC 共享库
$ find build-3/profiler/stage -name "libgrpc*.so*" -o -name "libprotobuf*.so*"
# 输出为空 ✅

$ find build-3/profiler/dist -name "libgrpc*.so*" -o -name "libprotobuf*.so*"
# 输出为空 ✅

# 检查是否有 lib/rdc/grpc 目录
$ ls build-3/profiler/stage/lib/rdc/grpc/
# 目录不存在 ✅
```

**原因**：RDC 的 CMakeLists.txt 检测到 `GRPC_ROOT=/usr`（默认值），跳过了 gRPC 安装。

**✅ 合规**：RDC 不重复安装 gRPC 文件，符合包职责边界原则。

---

### 4. RDC 的系统依赖检查 ✅

**rdcd 可执行文件的依赖**：
```bash
$ ldd build-3/profiler/dist/bin/rdcd
linux-vdso.so.1
libpthread.so.0 => /lib64/libpthread.so.0     # ✅ glibc
librt.so.1 => /lib64/librt.so.1               # ✅ glibc
libdl.so.2 => /lib64/libdl.so.2               # ✅ glibc
librdc_bootstrap.so.1 => .../lib/librdc_bootstrap.so.1  # ✅ 本地库
libstdc++.so.6 => /lib64/libstdc++.so.6       # ✅ gcc-toolset
libm.so.6 => /lib64/libm.so.6                 # ✅ glibc
libgcc_s.so.1 => /lib64/libgcc_s.so.1         # ✅ gcc-toolset
libc.so.6 => /lib64/libc.so.6                 # ✅ glibc
```

**✅ 合规**：
- 只依赖 glibc（2.28+）和 gcc-toolset 标准库
- 没有依赖额外的系统 `*-devel` 包
- 没有依赖系统的 gRPC 或 protobuf 库

---

### 5. RDC 的静态链接 gRPC ✅✅

**关键发现**：RDC 静态链接了 gRPC！

**验证**：
```bash
$ ldd build-3/profiler/dist/bin/rdcd | grep grpc
# 无输出 ✅ - 证明没有动态链接 gRPC

$ ldd build-3/profiler/dist/lib/librdc.so.1.2 | grep grpc
# 无输出 ✅ - 证明没有动态链接 gRPC

$ strings build-3/profiler/dist/bin/rdcd | grep -i "grpc" | head -5
_ZTHN9grpc_core8Activity19g_current_activity_E
_ZTHN9grpc_core7ExecCtx9exec_ctx_E
grpc.priH3
grpc-timI9
grpc-encI9
# ✅ 找到大量 gRPC 符号和字符串

$ size build-3/profiler/dist/bin/rdcd
   text	   data	    bss	    dec	    hex	filename
16136615	 369888	  47148	16553651	 fc96b3	rdcd
# ✅ text 段 16MB，包含了静态链接的 gRPC 代码（gRPC 静态库约 50MB+）
```

**✅✅ 最佳实践**：
- RDC 将 gRPC 静态链接，完全自包含
- 运行时无需 gRPC 共享库
- 避免了版本冲突和依赖管理复杂性
- 符合 manylinux 最佳实践

---

### 6. RDC 的 gRPC 工具使用 ✅

**protoc 和 grpc_cpp_plugin 使用**：
```bash
$ grep "protoc" build-3/logs/rdc_configure.log
GRPC_PLUGIN=/workspace/TheRock/build-3/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps/bin/grpc_cpp_plugin
protoc cmd:
  $ .../bin/protoc --proto_path=.../rdc/protos
    --plugin=protoc-gen-grpc=".../grpc_cpp_plugin" .../rdc.proto
protoc command returned: 0  ✅
```

**✅ 合规**：
- 使用 bundled 的 protoc 和 grpc_cpp_plugin
- 通过 CMAKE_PREFIX_PATH 自动找到
- 工具通过 RPATH 找到其依赖（zlib）

---

### 7. artifact.toml 配置 ✅

**profiler/artifact-rdc.toml**：
```toml
[components.dev."profiler/rdc/stage"]
include = [
  "include/**",
  "lib/cmake/**",
  "lib/rdc/grpc/**",  # ⚠️ 这个路径实际不存在（好事！）
]
```

**实际情况**：
- `lib/rdc/grpc/` 目录不存在（因为 RDC 没有安装 gRPC）
- artifact.toml 中的这一行可能是遗留配置
- 不影响构建，因为目录为空时 include 模式不匹配任何文件

**⚠️ 建议**：
- 可以清理 `lib/rdc/grpc/**` 这一行（可选）
- 或者保留作为文档说明（如果 RDC 源码改变行为）

---

## 📊 合规性总结表

| 检查项 | gRPC | RDC | 状态 |
|--------|------|-----|------|
| **安装位置** | `lib/rocm_sysdeps/` | N/A | ✅ 合规 |
| **SONAME 前缀** | `rocm_sysdeps_*` (zlib) | N/A | ✅ 合规 |
| **可重定位配置** | 相对路径 | N/A | ✅ 合规 |
| **RPATH 设置** | `$ORIGIN` relative | 继承 | ✅ 合规 |
| **静态库优先** | 主要静态链接 | 静态链接 gRPC | ✅✅ 最佳实践 |
| **符号版本** | `AMDROCM_SYSDEPS_1.0` (zlib) | N/A | ✅ 合规 |
| **find_package** | gRPCConfig.cmake | 使用标准机制 | ✅ 合规 |
| **无硬编码路径** | N/A | 完全移除 | ✅ 合规 |
| **系统依赖** | 只有 glibc/gcc-toolset | 只有 glibc/gcc-toolset | ✅ 合规 |
| **不重复安装** | N/A | 不安装 gRPC | ✅ 合规 |
| **构建工具** | protoc, plugins | 使用 bundled | ✅ 合规 |

---

## 🎯 关键发现

### ✅ 优秀设计 - 静态链接策略

**gRPC 和 RDC 采用静态链接策略，这是 manylinux 的最佳实践：**

1. **避免共享库冲突**
   - 系统可能安装了不同版本的 gRPC/protobuf
   - 静态链接确保使用特定版本，无冲突

2. **简化运行时依赖**
   - RDC 不需要动态查找 gRPC 库
   - 减少 RPATH 和 LD_LIBRARY_PATH 复杂性

3. **自包含分发**
   - RDC 二进制完全自包含（除了标准 glibc）
   - 可以在任何 glibc 2.28+ 系统上运行

4. **符合文档建议**
   - 文档明确："When it makes sense, we prefer to pull dependencies in as static libraries"
   - gRPC 作为 build-only 和 header-only 依赖，静态链接最合适

### ✅ 正确的包职责分离

**gRPC 包（therock-grpc）的职责：**
- ✅ 提供静态库（.a 文件）
- ✅ 提供构建工具（protoc, grpc_cpp_plugin）
- ✅ 提供 CMake 配置文件（gRPCConfig.cmake）
- ✅ 安装到 `lib/rocm_sysdeps/`
- ✅ 处理 SONAME 和 RPATH

**RDC 包的职责：**
- ✅ 声明对 gRPC 的依赖（RUNTIME_DEPS）
- ✅ 使用 find_package() 查找 gRPC
- ✅ 静态链接 gRPC 库
- ✅ 使用 gRPC 工具生成代码
- ✅ **不**复制/安装 gRPC 文件

### ✅ 依赖管理流程

```
1. TheRock 构建 therock-grpc
   ↓
   安装到：build-3/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps/

2. TheRock 构建 RDC
   ├── RUNTIME_DEPS: ${THEROCK_BUNDLED_GRPC}
   │   └── 设置 CMAKE_PREFIX_PATH += .../grpc/.../stage/lib/rocm_sysdeps
   │
   └── RDC CMake 配置
       ├── find_package(gRPC) → 找到 gRPCConfig.cmake ✅
       ├── find_package(protobuf) → 找到 protobufConfig.cmake ✅
       └── 静态链接 gRPC::grpc++ target ✅

3. RDC 构建
   ├── 使用 protoc 生成 .pb.cc 文件 ✅
   ├── 使用 grpc_cpp_plugin 生成 .grpc.pb.cc 文件 ✅
   └── 编译并静态链接 libgrpc++.a ✅

4. RDC 安装
   ├── 安装 RDC 自己的文件 ✅
   └── **不**安装 gRPC 文件（GRPC_ROOT=/usr 检测跳过）✅

5. TheRock 打包
   ├── 将 gRPC 工具复制到 profiler/dist/lib/rocm_sysdeps/bin/ ✅
   └── 这是 RUNTIME_DEPS 机制，不是 RDC 的职责 ✅
```

---

## ⚠️ 可选改进项

### 1. artifact-rdc.toml 中的 lib/rdc/grpc/**

**状态**：⚠️ 可选清理

**当前配置**：
```toml
[components.dev."profiler/rdc/stage"]
include = [
  "include/**",
  "lib/cmake/**",
  "lib/rdc/grpc/**",  # ← 这个路径实际不存在
]
```

**建议**：
- 选项 1：删除这一行（因为目录不存在）
- 选项 2：保留并添加注释，说明为何不再需要
- 选项 3：不改动（无实际影响）

**推荐**：选项 2 - 保留并注释
```toml
[components.dev."profiler/rdc/stage"]
include = [
  "include/**",
  "lib/cmake/**",
  # Note: lib/rdc/grpc/** is no longer needed as RDC statically links gRPC
  # and no longer installs gRPC files separately.
  # "lib/rdc/grpc/**",
]
```

---

## ✅ 最终结论

### 🎉 完全合规！

**gRPC 和 RDC 的实现完全符合 manylinux 构建规范：**

1. ✅ **安装位置正确**：gRPC 安装到 `lib/rocm_sysdeps/`
2. ✅ **SONAME 重写**：共享库使用 `rocm_sysdeps_` 前缀
3. ✅ **可重定位配置**：pkgconfig 和 CMake 配置使用相对路径
4. ✅ **RPATH 正确**：使用 origin-relative RPATH
5. ✅ **静态链接优先**：gRPC 主要作为静态库，RDC 静态链接
6. ✅ **依赖标准化**：使用 find_package() + CMAKE_PREFIX_PATH
7. ✅ **无硬编码路径**：完全移除所有硬编码路径
8. ✅ **系统依赖最小化**：只依赖 glibc 和 gcc-toolset
9. ✅ **包职责清晰**：gRPC 安装，RDC 使用但不重复安装
10. ✅ **构建工具可用**：protoc 和 plugins 正确安装和使用

### 🌟 设计亮点

1. **静态链接策略**：避免运行时依赖冲突，简化分发
2. **标准 CMake 实践**：使用 *Config.cmake 和 targets
3. **自动化 patch**：patch_install.sh 自动处理 SONAME 和重定位
4. **依赖管理清晰**：通过 RUNTIME_DEPS 明确依赖关系
5. **职责分离明确**：TheRock 管理打包，RDC 只使用不安装

### 📋 可选改进

1. ⚠️ 清理 artifact-rdc.toml 中的 `lib/rdc/grpc/**` 配置（可选，不影响功能）

---

## 📚 相关文档

- `docs/design/manylinux_builds.md` - ManyLinux 构建规范
- `third-party/sysdeps/linux/grpc/CMakeLists.txt` - gRPC 构建配置
- `third-party/sysdeps/linux/grpc/patch_install.sh` - gRPC patch 脚本
- `profiler/CMakeLists.txt` - RDC 构建配置
- `profiler/artifact-rdc.toml` - RDC 打包配置
- `build_tools/patch_linux_so.py` - SONAME patch 工具

---

**检查日期**：2025-11-09  
**检查人**：AI Assistant  
**结论**：✅ **完全合规，可以放心提交！** 🎉

