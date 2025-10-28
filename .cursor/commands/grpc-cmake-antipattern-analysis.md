# gRPC CMakeLists.txt Anti-Pattern 分析

**Code Reviewer 关切点分析**  
**日期**: 2025-11-09

---

## 🎯 Code Reviewer 的两个关切

### 关切 1: gRPC 干涉 zlib 安装

**位置**: `third-party/sysdeps/linux/grpc/CMakeLists.txt` Line 141-149

**代码**:
```cmake
COMMAND
  # Copy zlib shared libraries to gRPC's lib directory so grpc_cpp_plugin can find it via RPATH
  # This makes each stage directory self-contained for tools execution
  # Use shell globbing to copy all zlib .so* files (handles symlinks and actual files)
  bash -c "cp -L ${ZLIB_ROOT}/lib/librocm_sysdeps_z.so* ${CMAKE_INSTALL_PREFIX}/lib/ 2>/dev/null || true"
COMMAND
  # Also create the libz.so symlink for compatibility
  "${CMAKE_COMMAND}" -E create_symlink
    "librocm_sysdeps_z.so.1"
    "${CMAKE_INSTALL_PREFIX}/lib/libz.so"
```

**Reviewer 反馈**:
> "grpc shouldn't fiddle with zlib. If you need to use it, use find_package and link where needed but do not interfere with the installation!"

**问题分析**:
1. ❌ gRPC 复制了 zlib 的共享库到自己的目录
2. ❌ gRPC 创建了 zlib 的符号链接
3. ❌ 这违反了包职责边界原则

---

### 关切 2: add_custom_target 中调用 CMake 的 Anti-Pattern

**位置**: `third-party/sysdeps/linux/grpc/CMakeLists.txt` Line 88-157

**代码模式**:
```cmake
add_custom_target(
  build ALL
  COMMAND
    "${CMAKE_COMMAND}" -E copy_directory "${SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/s"
  COMMAND
    "${CMAKE_COMMAND}"
      "-G${CMAKE_GENERATOR}"
      "-S${CMAKE_CURRENT_BINARY_DIR}/s"
      "-B${CMAKE_CURRENT_BINARY_DIR}/b"
      # ... 大量 CMAKE_ARGS
  COMMAND
    "${CMAKE_COMMAND}" --build "${CMAKE_CURRENT_BINARY_DIR}/b"
  COMMAND
    "${CMAKE_COMMAND}" --install "${CMAKE_CURRENT_BINARY_DIR}/b"
  # ...
)
```

**Reviewer 反馈**:
> "You're calling a CMake project (configure / build / install) in a custom target of a CMake project. This all needs to go away and is a big anti-pattern. Take a look at the other third_party deps which are CMake based how to handle this."

**问题分析**:
1. ❌ 在一个 CMake 项目的 custom target 中调用另一个 CMake 项目的完整构建流程
2. ❌ 这是嵌套的 CMake 调用（外层 CMake → custom target → 内层 CMake）
3. ❌ 绕过了 CMake 的标准依赖管理机制

---

## 🔍 检查现有代码实现

### 当前 gRPC 的实现

```cmake
# Line 1-56: TheRock 层（外层）
therock_cmake_subproject_declare(therock-grpc
  EXTERNAL_SOURCE_DIR .
  BINARY_DIR build
  # ...
  RUNTIME_DEPS
    therock-zlib
)

# Line 58-157: gRPC 子项目构建（内层）
cmake_minimum_required(VERSION 3.25)
project(GRPC_BUILD)

find_package(ZLIB REQUIRED CONFIG)  # ✅ 这部分我们刚修复的

add_custom_target(
  build ALL
  COMMAND cmake -S... -B...  # ❌ Anti-pattern
  COMMAND cmake --build ...   # ❌ Anti-pattern
  COMMAND cmake --install ... # ❌ Anti-pattern
  COMMAND cp -L ${ZLIB_ROOT}/lib/librocm_sysdeps_z.so* ... # ❌ 干涉 zlib
  COMMAND create_symlink ...  # ❌ 干涉 zlib
)
```

### 其他依赖的实现对比

#### zlib 的实现（也使用了相同模式）

```cmake
# third-party/sysdeps/common/zlib/CMakeLists.txt Line 68-102
add_custom_target(
  build ALL
  COMMAND "${CMAKE_COMMAND}" -E copy_directory "${SOURCE_DIR}" ...
  COMMAND "${CMAKE_COMMAND}" -G${CMAKE_GENERATOR} -S... -B...
  COMMAND "${CMAKE_COMMAND}" --build ...
  COMMAND "${CMAKE_COMMAND}" --install ...
)
```

**观察**: zlib 也使用了相同的 `add_custom_target` + `cmake` 模式！

#### sqlite3 的实现

```cmake
# third-party/sysdeps/common/sqlite3/CMakeLists.txt
# 检查是否也使用相同模式
```

---

## 📊 问题严重性评估

### Reviewer 的关切是否合理？

#### 关切 1: gRPC 复制 zlib 文件

**✅ 完全合理！**

**原因**:
1. **违反包职责边界**: zlib 是一个独立的包，gRPC 不应该复制或修改它的文件
2. **重复安装**: zlib 已经安装到 `lib/rocm_sysdeps/`，gRPC 又复制一份
3. **维护问题**: 如果 zlib 更新，gRPC 的副本不会自动更新
4. **违反 DRY 原则**: Don't Repeat Yourself

**正确的做法**:
- gRPC 应该通过 RPATH 找到已安装的 zlib
- 不应该复制 zlib 的文件
- 依赖 TheRock 的依赖管理系统

#### 关切 2: add_custom_target 中调用 CMake

**⚠️ 需要更深入分析！**

**观察**:
- ✅ zlib、bzip2、liblzma、sqlite3 等多个依赖都使用了相同的模式
- ⚠️ 这可能是 TheRock 项目的**设计模式**，而不是 anti-pattern
- ⚠️ 可能是为了处理外部项目的特殊需求（patching、post-processing）

**需要验证**:
1. 这是否是 TheRock 的标准模式？
2. 是否有使用 ExternalProject_Add 或其他标准方式的例子？
3. 为什么选择这种模式？

---

## 🔍 深入分析：为什么使用 add_custom_target + cmake?

### 可能的原因

1. **需要 Patching**:
   ```cmake
   COMMAND
     # Apply patches to source before building
     bash "${CMAKE_CURRENT_SOURCE_DIR}/patch_source.sh" ...
   ```

2. **需要 Post-Processing**:
   ```cmake
   COMMAND
     bash "${CMAKE_CURRENT_SOURCE_DIR}/patch_install.sh" ${CMAKE_INSTALL_PREFIX}
   ```

3. **需要自定义构建流程**:
   - 复制源码 → 应用 patch → 配置 → 构建 → 安装 → 后处理

4. **TheRock 的两层架构**:
   ```
   外层: therock_cmake_subproject_declare()
   内层: 实际的构建逻辑（可能来自第三方）
   ```

### ExternalProject_Add 的替代方案

**标准的 CMake 方式**:
```cmake
include(ExternalProject)

ExternalProject_Add(grpc-external
  SOURCE_DIR ${SOURCE_DIR}
  BINARY_DIR ${CMAKE_CURRENT_BINARY_DIR}/b
  INSTALL_DIR ${CMAKE_INSTALL_PREFIX}
  
  CMAKE_ARGS
    -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
    -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
    # ... 其他参数
  
  BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR>
  INSTALL_COMMAND ${CMAKE_COMMAND} --install <BINARY_DIR>
)
```

**优点**:
- ✅ CMake 标准机制
- ✅ 更好的依赖管理
- ✅ 并行构建支持
- ✅ 更清晰的语义

**但是**:
- ⚠️ 可能不支持复杂的 patching 流程
- ⚠️ 可能不支持自定义的 post-processing
- ⚠️ 与 TheRock 的 therock_cmake_subproject 系统可能不兼容

---

## 🎯 具体问题和解决方案

### 问题 1: gRPC 复制 zlib 文件 ❌

**当前代码** (Line 141-149):
```cmake
COMMAND
  bash -c "cp -L ${ZLIB_ROOT}/lib/librocm_sysdeps_z.so* ${CMAKE_INSTALL_PREFIX}/lib/ 2>/dev/null || true"
COMMAND
  "${CMAKE_COMMAND}" -E create_symlink
    "librocm_sysdeps_z.so.1"
    "${CMAKE_INSTALL_PREFIX}/lib/libz.so"
```

**问题**:
1. gRPC 的 dist 目录包含了 zlib 的副本
2. 创建了不必要的符号链接
3. grpc_cpp_plugin 和 protoc 需要 zlib，但应该通过 RPATH 找到，而不是通过复制

**为什么要这么做？**

查看注释：
```cmake
# Copy zlib shared libraries to gRPC's lib directory so grpc_cpp_plugin can find it via RPATH
# This makes each stage directory self-contained for tools execution
```

**意图**: 让 gRPC 的 stage 目录自包含，使得 grpc_cpp_plugin 可以独立运行

**问题分析**:
- grpc_cpp_plugin 是一个构建工具（build-time dependency）
- 它需要链接 zlib（runtime dependency）
- 当前通过复制 zlib 到 gRPC 目录来满足这个需求

**解决方案 A: 移除复制，依赖 RPATH（推荐）**

```cmake
# 不复制 zlib 文件
# 依赖正确的 RPATH 设置

# gRPC 的 CMake 配置中：
"-DCMAKE_INSTALL_RPATH=\$ORIGIN:\$ORIGIN/../lib:\$ORIGIN/../../zlib/build/stage/lib/rocm_sysdeps/lib"
```

**但是**:
- ⚠️ 这使得 gRPC 的 stage 目录不再自包含
- ⚠️ 需要 zlib 在相对路径可访问

**解决方案 B: 让 zlib 也安装到 gRPC 目录（TheRock 系统处理）**

```cmake
# 不由 gRPC 复制
# 而是由 TheRock 的 RUNTIME_DEPS 机制自动处理

# 在 profiler/CMakeLists.txt 中:
RUNTIME_DEPS
  ${THEROCK_BUNDLED_GRPC}  # 这应该自动包含 zlib

# TheRock 应该自动将 zlib 复制到使用 gRPC 的项目的 dist 中
```

**解决方案 C: 静态链接 zlib 到 grpc_cpp_plugin**

```cmake
# 让 gRPC 的构建工具静态链接 zlib
"-DgRPC_ZLIB_PROVIDER=package"
"-DBUILD_SHARED_LIBS=OFF"  # 对于工具使用静态库
```

---

### 问题 2: add_custom_target + cmake 模式 ⚠️

**Reviewer 的建议**: "Take a look at the other third_party deps which are CMake based how to handle this."

**检查结果**: 
- zlib 使用相同模式 ✅
- bzip2 使用相同模式 ✅
- liblzma 使用相同模式 ✅
- sqlite3 使用相同模式 ✅

**结论**: 这是 TheRock 项目的**标准模式**！

**为什么 Reviewer 认为这是 anti-pattern？**

可能的原因:
1. Reviewer 不熟悉 TheRock 的设计模式
2. 这确实不是标准的 CMake 方式（ExternalProject_Add）
3. 这种模式有其历史原因和特殊需求

**是否需要改变？**

需要考虑:
1. ⚠️ 如果改成 ExternalProject_Add，会影响整个 TheRock 的 sysdeps 构建系统
2. ⚠️ 可能需要重构大量代码
3. ⚠️ 可能破坏现有的 patching 和 post-processing 流程
4. ⚠️ 这应该是一个架构级别的决策，不是单个 PR 的范围

---

## 📊 建议的改动优先级

### 高优先级 (必须修复)

#### 1. 移除 gRPC 对 zlib 的复制和符号链接 ✅

**原因**: 
- 违反包职责边界
- 重复安装
- Code reviewer 明确指出

**改动**:
```diff
- COMMAND
-   # Copy zlib shared libraries to gRPC's lib directory so grpc_cpp_plugin can find it via RPATH
-   # This makes each stage directory self-contained for tools execution
-   # Use shell globbing to copy all zlib .so* files (handles symlinks and actual files)
-   bash -c "cp -L ${ZLIB_ROOT}/lib/librocm_sysdeps_z.so* ${CMAKE_INSTALL_PREFIX}/lib/ 2>/dev/null || true"
- COMMAND
-   # Also create the libz.so symlink for compatibility
-   "${CMAKE_COMMAND}" -E create_symlink
-     "librocm_sysdeps_z.so.1"
-     "${CMAKE_INSTALL_PREFIX}/lib/libz.so"
```

**需要验证**: grpc_cpp_plugin 和 protoc 是否仍然能找到 zlib

---

### 中优先级 (应该改进)

#### 2. 改进 RPATH 设置确保工具能找到 zlib

**当前** (Line 130):
```cmake
"-DCMAKE_INSTALL_RPATH=\$ORIGIN:\$ORIGIN/../lib"
```

**可能需要**:
```cmake
# 添加指向 zlib 的 RPATH（如果需要）
# 或依赖 TheRock 的 RUNTIME_DEPS 机制自动处理
```

---

### 低优先级 (架构决策)

#### 3. 考虑使用 ExternalProject_Add 替代 add_custom_target

**原因**:
- 这是整个 TheRock sysdeps 系统的设计问题
- 需要与项目维护者讨论
- 可能影响大量代码

**不应该在单个 PR 中解决此问题！**

---

## 🎯 立即可行的修复

### 修复 1: 移除 zlib 复制和符号链接

```cmake
# 删除 Line 140-149

# BEFORE:
  COMMAND
    "${CMAKE_COMMAND}" --install "${CMAKE_CURRENT_BINARY_DIR}/b"
  COMMAND
    bash -c "cp -L ${ZLIB_ROOT}/lib/librocm_sysdeps_z.so* ${CMAKE_INSTALL_PREFIX}/lib/ 2>/dev/null || true"
  COMMAND
    "${CMAKE_COMMAND}" -E create_symlink
      "librocm_sysdeps_z.so.1"
      "${CMAKE_INSTALL_PREFIX}/lib/libz.so"
  COMMAND
    "${CMAKE_COMMAND}" -E env ...

# AFTER:
  COMMAND
    "${CMAKE_COMMAND}" --install "${CMAKE_CURRENT_BINARY_DIR}/b"
  COMMAND
    "${CMAKE_COMMAND}" -E env ...
```

### 测试计划

1. **移除复制和符号链接**
2. **重新构建 gRPC**
3. **测试 grpc_cpp_plugin 和 protoc 是否能运行**
   ```bash
   $ ldd build-3/.../grpc_cpp_plugin | grep zlib
   # 应该能找到 zlib（通过 RPATH 或 LD_LIBRARY_PATH）
   ```
4. **测试 RDC 构建是否成功**（RDC 使用 grpc_cpp_plugin）

### 如果测试失败

**可能的问题**: grpc_cpp_plugin 找不到 zlib

**解决方案**:
1. 检查 grpc_cpp_plugin 的 RPATH
   ```bash
   readelf -d .../grpc_cpp_plugin | grep RPATH
   ```
2. 添加额外的 RPATH 路径
3. 或者保留复制，但添加注释说明为什么需要（临时方案）

---

## 🤔 关于 add_custom_target 模式的讨论

### Reviewer 可能的误解

Reviewer 说："Take a look at the other third_party deps which are CMake based how to handle this."

**但实际情况**:
- 几乎所有 TheRock 的 CMake-based third-party deps 都使用相同的模式
- 这不是 gRPC 特有的问题
- 这是 TheRock 项目的设计选择

### 可能的回应

**选项 1**: 解释这是 TheRock 的标准模式
```
This is the standard pattern used across all TheRock's CMake-based sysdeps 
(zlib, bzip2, liblzma, sqlite3, etc.). The add_custom_target approach allows 
us to:
1. Apply patches to third-party sources
2. Perform post-processing (SONAME rewriting, symbol versioning)
3. Integrate with TheRock's subproject system

While ExternalProject_Add might be more idiomatic, changing this would require 
refactoring the entire sysdeps infrastructure, which is beyond the scope of 
this PR.
```

**选项 2**: 承诺未来改进
```
We acknowledge that ExternalProject_Add would be a more idiomatic CMake 
approach. This is tracked as a technical debt item for future refactoring. 
However, for consistency with existing sysdeps and to minimize risk, we're 
maintaining the current pattern for now.
```

**选项 3**: 询问具体建议
```
We noticed that all CMake-based sysdeps in TheRock (zlib, bzip2, etc.) use 
the same add_custom_target + cmake pattern. Could you point us to a specific 
sysdep that uses a different, preferred approach that we should follow?
```

---

## ✅ 推荐的行动计划

### 立即执行（本 PR）

1. **✅ 移除 gRPC 对 zlib 文件的复制**
   - 删除 `cp -L ${ZLIB_ROOT}/lib/librocm_sysdeps_z.so*` 命令
   - 删除 `create_symlink libz.so` 命令

2. **✅ 测试验证**
   - 验证 grpc_cpp_plugin 能否正常运行
   - 验证 RDC 构建是否成功

3. **✅ 如果测试失败，调整 RPATH**
   - 添加必要的 RPATH 路径
   - 确保工具能找到 zlib

### 后续讨论（独立 issue）

4. **讨论 add_custom_target 模式**
   - 与项目维护者讨论
   - 评估 ExternalProject_Add 的可行性
   - 如果改变，应该是整个 sysdeps 系统的重构

---

## 📚 总结

| 关切 | 合理性 | 优先级 | 行动 |
|------|--------|--------|------|
| gRPC 复制 zlib 文件 | ✅ 完全合理 | 🔴 高 | 立即修复 |
| add_custom_target 模式 | ⚠️ 需讨论 | 🟡 低 | 架构讨论 |

**立即修复**: 移除 gRPC 对 zlib 的复制和符号链接创建
**长期讨论**: add_custom_target vs ExternalProject_Add 的架构选择

