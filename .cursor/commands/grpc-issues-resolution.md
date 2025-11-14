# gRPC Code Review 问题解决方案

**日期**: 2025-11-09  
**分析完成**: Code Reviewer 关切的合理性和解决方案

---

## 🎯 Code Reviewer 关切总结

### 关切 1: gRPC 复制 zlib 文件

**代码位置**: `third-party/sysdeps/linux/grpc/CMakeLists.txt` Line 141-149

**Reviewer 意见**:
> "grpc shouldn't fiddle with zlib. If you need to use it, use find_package and link where needed but do not interfere with the installation!"

**✅ 完全合理！**

### 关切 2: add_custom_target 中调用 CMake

**代码位置**: `third-party/sysdeps/linux/grpc/CMakeLists.txt` Line 88-157

**Reviewer 意见**:
> "You're calling a CMake project (configure / build / install) in a custom target of a CMake project. This all needs to go away and is a big anti-pattern. Take a look at the other third_party deps which are CMake based how to handle this."

**⚠️ 需要澄清！这是 TheRock 的标准模式！**

---

## 📊 调查结果

### 发现 1: 为什么复制 zlib？

**实际问题**:
```bash
$ ldd build-3/.../grpc_cpp_plugin
librocm_sysdeps_z.so.1 => .../lib/librocm_sysdeps_z.so.1

$ readelf -d .../grpc_cpp_plugin | grep RUNPATH
Library runpath: [$ORIGIN:$ORIGIN/../lib]
```

**原因**:
1. grpc_cpp_plugin 需要动态链接 zlib
2. RUNPATH 是 `$ORIGIN:$ORIGIN/../lib`
3. 如果不复制 zlib 到 grpc 的 lib/，grpc_cpp_plugin 找不到 zlib
4. grpc_cpp_plugin 在 `bin/` 目录，通过 `$ORIGIN/../lib` 找到 `lib/librocm_sysdeps_z.so.1`

**问题**:
- ❌ gRPC 包不应该包含 zlib 的副本
- ❌ 这违反了包职责边界

### 发现 2: TheRock 的其他依赖都使用相同模式

**检查结果**:
```bash
# zlib, bzip2, liblzma, zstd - 都使用 add_custom_target + cmake
# sqlite3 - 直接使用 add_library (因为很简单)
```

**结论**: add_custom_target + cmake 是 TheRock 处理需要 patching 和 post-processing 的依赖的**标准模式**

---

## ✅ 解决方案

### 问题 1: 移除 gRPC 对 zlib 的复制

#### 选项 A: 调整 RPATH（推荐）

**思路**: 让 grpc_cpp_plugin 的 RPATH 指向 zlib 的安装位置

**实现**:
```cmake
# 修改 Line 130
# 原来:
"-DCMAKE_INSTALL_RPATH=\$ORIGIN:\$ORIGIN/../lib"

# 改为:
"-DCMAKE_INSTALL_RPATH=\$ORIGIN:\$ORIGIN/../lib:\$ORIGIN/../../../zlib/build/stage/lib/rocm_sysdeps/lib"
```

**问题**: 硬编码了相对路径，假设了目录结构

#### 选项 B: 依赖 LD_LIBRARY_PATH（运行时）

**思路**: 在运行 grpc_cpp_plugin 时设置 LD_LIBRARY_PATH

**问题**: 
- ❌ 不适用于 manylinux
- ❌ 需要修改使用 grpc_cpp_plugin 的地方

#### 选项 C: 静态链接 zlib 到 grpc_cpp_plugin（最佳）

**思路**: 让 gRPC 的构建工具静态链接 zlib，避免运行时依赖

**实现**:
```cmake
# 在 gRPC 的 CMAKE_ARGS 中添加
"-DBUILD_SHARED_LIBS=OFF"  # 或者只对工具使用静态库

# 或者配置 gRPC 让工具使用静态 zlib
"-DgRPC_ZLIB_PROVIDER=package"
"-DZLIB_USE_STATIC_LIBS=ON"  # 如果 gRPC 支持
```

**优点**:
- ✅ grpc_cpp_plugin 不再需要运行时 zlib
- ✅ 移除对 zlib 文件复制的需求
- ✅ 符合"构建工具应该自包含"的原则

**需要验证**: gRPC 是否支持对工具使用静态 zlib

#### 选项 D: 不复制 zlib，让使用者处理（TheRock 标准方式）

**思路**: 
1. gRPC 不复制 zlib
2. gRPC 声明 RUNTIME_DEPS: therock-zlib
3. 使用 gRPC 的项目（如 RDC）通过 RUNTIME_DEPS 自动获得 zlib

**实现**:
```cmake
# gRPC/CMakeLists.txt - 移除复制命令
# 删除 Line 140-149

# 使用者（如 RDC）已经有:
RUNTIME_DEPS
  ${THEROCK_BUNDLED_GRPC}  # 这应该传递 zlib 依赖
```

**问题**: 
- ⚠️ grpc_cpp_plugin 本身在 gRPC 构建时就需要 zlib
- ⚠️ 在 gRPC 的测试阶段可能找不到 zlib

#### 选项 E: 混合方案（实用主义）

**思路**: 
1. 移除"复制整个 zlib"的操作
2. 只在 gRPC 内部构建时设置 CMAKE_BUILD_RPATH 指向 zlib
3. 安装时不包含 zlib 副本
4. 依赖使用者的 RUNTIME_DEPS 机制

**实现**:
```cmake
# 删除 Line 140-149 (复制和符号链接)

# 保留 Line 134-135 (构建时 RPATH)
"-DCMAKE_BUILD_RPATH=${ZLIB_ROOT}/lib"
"-DCMAKE_SKIP_BUILD_RPATH=OFF"

# 安装后，grpc_cpp_plugin 的 RUNPATH 只有 $ORIGIN:$ORIGIN/../lib
# 当 RDC 或其他项目使用时，它们的 RUNTIME_DEPS 会提供 zlib
```

**问题分析**:

1. **gRPC 构建阶段**: 
   - gRPC 内部使用 grpc_cpp_plugin 生成代码
   - CMAKE_BUILD_RPATH 指向 zlib → 构建时能找到 ✅

2. **gRPC 安装后**:
   - grpc_cpp_plugin 安装到 `bin/`
   - RUNPATH 是 `$ORIGIN:$ORIGIN/../lib`
   - `lib/` 目录没有 zlib → grpc_cpp_plugin 无法独立运行 ❌

3. **RDC 使用 grpc_cpp_plugin 时**:
   - RDC 的 RUNTIME_DEPS 包含 ${THEROCK_BUNDLED_GRPC}
   - TheRock 应该自动设置 LD_LIBRARY_PATH 或复制 zlib
   - 需要验证 TheRock 是否这样处理 ⚠️

---

## 🎯 推荐方案（分步骤）

### 步骤 1: 移除复制，测试失败情况

```cmake
# 删除 Line 140-149
# 不复制 zlib，不创建符号链接
```

**预期**: RDC 构建会失败，因为 grpc_cpp_plugin 找不到 zlib

### 步骤 2: 验证失败原因

```bash
$ build-3/third-party/sysdeps/linux/grpc/build/dist/lib/rocm_sysdeps/bin/grpc_cpp_plugin --version
error while loading shared libraries: librocm_sysdeps_z.so.1: cannot open shared object file
```

### 步骤 3A: 如果 gRPC 支持，静态链接工具

```cmake
# 查看 gRPC 的 CMakeLists.txt，看是否可以配置工具使用静态 zlib
# 如果可以，添加相应的 CMAKE_ARGS
```

### 步骤 3B: 如果不支持，调整 RPATH 策略

**方案 1: 让 TheRock 的 RUNTIME_DEPS 自动处理**

检查 `cmake/therock_subproject.cmake` 是否在使用工具时自动设置 LD_LIBRARY_PATH

**方案 2: 保留最小的符号链接（妥协）**

```cmake
# 只复制 librocm_sysdeps_z.so.1（不复制所有 .so*）
# 添加明确的注释说明为什么需要
COMMAND
  # TEMPORARY: grpc_cpp_plugin needs zlib at runtime
  # TODO: Either static link zlib to tools, or have TheRock provide zlib via RUNTIME_DEPS
  "${CMAKE_COMMAND}" -E copy_if_different
    "${ZLIB_ROOT}/lib/librocm_sysdeps_z.so.1"
    "${CMAKE_INSTALL_PREFIX}/lib/librocm_sysdeps_z.so.1"
```

---

## 🔍 问题 2: add_custom_target 模式

### Reviewer 的误解

Reviewer 说："Take a look at the other third_party deps"

**但实际上**:
- zlib, bzip2, liblzma, zstd 都使用相同的 add_custom_target + cmake 模式
- 这是 TheRock 的**标准方式**，不是 anti-pattern

### 为什么使用这种模式？

1. **需要 patching**: 
   ```cmake
   bash "${CMAKE_CURRENT_SOURCE_DIR}/patch_source.sh"
   ```

2. **需要 post-processing**:
   ```cmake
   bash "${CMAKE_CURRENT_SOURCE_DIR}/patch_install.sh"
   # SONAME 重写、符号版本等
   ```

3. **两层架构**:
   ```
   外层: therock_cmake_subproject_declare
   内层: 实际构建（来自第三方）+ 自定义处理
   ```

### sqlite3 的例外

sqlite3 使用 `add_library` 因为:
- 它只是一个单文件 (sqlite3.c)
- 不需要复杂的构建流程
- 可以直接在 CMake 中定义

### 应对策略

**选项 A: 解释这是标准模式**

```
This add_custom_target pattern is used consistently across TheRock's CMake-based 
sysdeps (zlib, bzip2, liblzma, zstd) because we need to:
1. Apply patches to third-party sources
2. Perform post-processing (SONAME rewriting, symbol versioning)
3. Integrate with manylinux requirements

sqlite3 is an exception because it's simple enough to use add_library directly.
```

**选项 B: 承认可以改进，但超出范围**

```
We acknowledge that ExternalProject_Add would be more idiomatic. However:
1. This pattern is used consistently across all similar sysdeps
2. Changing it would require refactoring the entire sysdeps infrastructure
3. This is tracked as technical debt for future work

For this PR, we're maintaining consistency with existing patterns.
```

**选项 C: 请求具体指导**

```
We've checked other CMake-based sysdeps (zlib, bzip2, liblzma) and they all 
use the same pattern. Could you point us to a specific example that uses the 
preferred approach you mentioned?
```

---

## ✅ 立即行动计划

### 1. 移除 zlib 复制（必须）

```diff
# Line 140-149 删除
- COMMAND
-   bash -c "cp -L ${ZLIB_ROOT}/lib/librocm_sysdeps_z.so* ${CMAKE_INSTALL_PREFIX}/lib/ 2>/dev/null || true"
- COMMAND
-   "${CMAKE_COMMAND}" -E create_symlink
-     "librocm_sysdeps_z.so.1"
-     "${CMAKE_INSTALL_PREFIX}/lib/libz.so"
```

### 2. 测试验证

```bash
# 重新构建 gRPC
rm -rf build-3/third-party/sysdeps/linux/grpc/
cmake --build build-3 --target therock-grpc

# 测试 grpc_cpp_plugin
build-3/.../grpc_cpp_plugin --version

# 构建 RDC (使用 grpc_cpp_plugin)
cmake --build build-3 --target rdc
```

### 3. 如果失败，实施备选方案

**备选 A**: 调查 gRPC 的静态链接选项
**备选 B**: 添加 RPATH 指向 zlib
**备选 C**: 最小化的文件复制 + 详细注释

### 4. 关于 add_custom_target 模式

- 准备解释为什么使用这种模式
- 指出其他依赖也使用相同模式
- 如果 reviewer 坚持，询问具体的替代方案示例

---

## 📝 建议的 PR 回复

### 针对 zlib 复制问题

```markdown
Good catch! You're absolutely right that gRPC shouldn't copy zlib files.

The current implementation copies zlib to make grpc_cpp_plugin self-contained,
but this violates package boundaries.

I've removed the zlib copying and symlinking. The challenge is that grpc_cpp_plugin
needs zlib at runtime. I'm testing a few approaches:

1. Static linking zlib to grpc_cpp_plugin (cleanest)
2. Relying on TheRock's RUNTIME_DEPS to provide zlib when tools are used
3. Adjusting RPATH if needed

Will update once testing is complete.
```

### 针对 add_custom_target 问题

```markdown
Regarding the add_custom_target pattern:

I've checked other CMake-based sysdeps in TheRock (zlib, bzip2, liblzma, zstd), 
and they all use the same add_custom_target + cmake pattern. This is because we need to:

1. Apply patches to third-party sources before building
2. Perform post-processing after install (SONAME rewriting, symbol versioning for manylinux)
3. Integrate with TheRock's subproject infrastructure

sqlite3 is an exception because it's simple enough to use add_library directly.

Could you point me to a specific sysdep that demonstrates the preferred approach? 
If this is about moving to ExternalProject_Add, that would be a great improvement 
but would require refactoring the entire sysdeps system, which might be beyond 
the scope of this PR.

Happy to discuss the best path forward!
```

---

## ✅ 最终检查清单

- [ ] 移除 zlib 文件复制（Line 140-149）
- [ ] 重新构建 gRPC
- [ ] 测试 grpc_cpp_plugin 能否运行
- [ ] 测试 RDC 构建是否成功
- [ ] 如果失败，实施备选方案
- [ ] 更新文档和注释
- [ ] 准备 PR 回复解释

---

**结论**: 
- ✅ Reviewer 对 zlib 复制的关切**完全合理**，必须修复
- ⚠️ Reviewer 对 add_custom_target 的关切需要**澄清**，这是 TheRock 的标准模式

