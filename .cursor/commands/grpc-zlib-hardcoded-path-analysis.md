# gRPC 的 zlib 硬编码路径问题分析

## 🎯 Code Reviewer 的关切

Code reviewer 指出 `third-party/sysdeps/linux/grpc/CMakeLists.txt` 中的硬编码路径问题：

```cmake
set(ZLIB_ROOT "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/zlib/build/stage/lib/rocm_sysdeps")
set(ZLIB_INCLUDE_DIR "${ZLIB_ROOT}/include")
set(ZLIB_LIBRARY "${ZLIB_ROOT}/lib/libz.so")
```

**反馈**：
> "This needs to a correctly modeled dep on zlib and to use find_package(). This is a big anti-pattern."

**要求**：
1. 正确建模 zlib 依赖
2. 使用 `find_package()`
3. 移除硬编码路径

---

## 📖 当前实现分析

### 1. gRPC 的依赖声明（外层 CMakeLists.txt, line 1-56）

```cmake
therock_cmake_subproject_declare(therock-grpc
  EXTERNAL_SOURCE_DIR .
  BINARY_DIR build
  # ...
  CMAKE_ARGS
    "-DSOURCE_DIR=${_source_dir}"
    "-DPATCHELF=${PATCHELF}"
    "-DTHEROCK_SOURCE_DIR=${THEROCK_SOURCE_DIR}"
    "-DTHEROCK_BINARY_DIR=${THEROCK_BINARY_DIR}"  # ← 传递了 BINARY_DIR！
    "-DPython3_EXECUTABLE=${Python3_EXECUTABLE}"
  RUNTIME_DEPS
    therock-zlib  # ✅ 正确声明了依赖
  # ...
)
```

**✅ 好的部分**：
- 声明了 `RUNTIME_DEPS: therock-zlib`
- 这确保 zlib 在 gRPC 之前构建

**❌ 问题**：
- 传递了 `THEROCK_BINARY_DIR` 给子项目
- 子项目使用这个变量构造硬编码路径

---

### 2. gRPC 子项目构建（line 58-148）

```cmake
# Otherwise, this is the sub-project build.
cmake_minimum_required(VERSION 3.25)
project(GRPC_BUILD)

# ❌ 硬编码路径
set(ZLIB_ROOT "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/zlib/build/stage/lib/rocm_sysdeps")
set(ZLIB_INCLUDE_DIR "${ZLIB_ROOT}/include")
set(ZLIB_LIBRARY "${ZLIB_ROOT}/lib/libz.so")

message(STATUS "Using zlib from: ${ZLIB_ROOT}")

# 然后传递给内部 gRPC 的 CMake
add_custom_target(
  build ALL
  COMMAND
    "${CMAKE_COMMAND}"
      # ...
      "-DgRPC_ZLIB_PROVIDER=package"
      "-DZLIB_ROOT=${ZLIB_ROOT}"               # ❌ 传递硬编码路径
      "-DZLIB_INCLUDE_DIR=${ZLIB_INCLUDE_DIR}" # ❌ 传递硬编码路径
      "-DZLIB_LIBRARY=${ZLIB_LIBRARY}"         # ❌ 传递硬编码路径
      # ...
)
```

**问题分析**：
1. 硬编码了完整的路径：`${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/zlib/build/stage/...`
2. 没有使用 `find_package(ZLIB)`
3. 即使 zlib 提供了 `ZLIBConfig.cmake`，这里也没有使用

---

### 3. zlib 的包提供（zlib/CMakeLists.txt）

```cmake
therock_cmake_subproject_declare(therock-zlib
  # ...
  INSTALL_DESTINATION
    lib/rocm_sysdeps
  INTERFACE_PKG_CONFIG_DIRS
    lib/rocm_sysdeps/lib/pkgconfig
)
therock_cmake_subproject_provide_package(therock-zlib ZLIB lib/rocm_sysdeps/lib/cmake/ZLIB)
```

**✅ zlib 正确提供了包配置**：
- 安装位置：`lib/rocm_sysdeps/`
- CMake 配置：`lib/rocm_sysdeps/lib/cmake/ZLIB/ZLIBConfig.cmake`
- pkgconfig：`lib/rocm_sysdeps/lib/pkgconfig/zlib.pc`

---

### 4. TheRock 的依赖管理机制

**therock_subproject.cmake 的关键代码**：

```cmake
# Line 666-667: 处理 RUNTIME_DEPS
_therock_cmake_subproject_setup_deps(_deps_contents _deps_provided THEROCK_DIST_DIR ${_runtime_deps})
_therock_cmake_subproject_setup_deps(_deps_contents _deps_provided THEROCK_DIST_DIR ${_build_deps})

# Line 669: 添加依赖内容到 init 文件
string(APPEND _init_contents "${_deps_contents}")

# Line 672: 设置 CMAKE_PREFIX_PATH
string(APPEND _init_contents "list(PREPEND CMAKE_PREFIX_PATH \"@_prefix_dir@\")\n")
```

**预期机制**：
1. `RUNTIME_DEPS` 应该将依赖的 dist 目录添加到 `CMAKE_PREFIX_PATH`
2. 子项目的 CMake 应该自动继承这个 `CMAKE_PREFIX_PATH`
3. `find_package(ZLIB)` 应该能找到 `ZLIBConfig.cmake`

---

## 🔍 问题根源

### 核心问题：两层 CMake 嵌套

gRPC 的构建使用了 **两层 CMake 嵌套**：

```
TheRock (顶层 CMake)
└── gRPC 外层 (therock_cmake_subproject)
    └── gRPC 内层 (add_custom_target + cmake ...)
        └── 真正的 gRPC CMake (源自 github.com/grpc/grpc)
```

**第一层**（gRPC 外层，line 1-56）：
- 由 TheRock 的 `therock_cmake_subproject_declare` 管理
- 继承 TheRock 的 `CMAKE_PREFIX_PATH`（包含 zlib）
- 这一层 **可以** 使用 `find_package(ZLIB)`

**第二层**（gRPC 内层，line 58-148）：
- 这是一个 `add_custom_target` + `cmake` 命令
- **启动一个新的 CMake 进程**
- 不自动继承第一层的 `CMAKE_PREFIX_PATH`！
- 当前通过 `CMAKE_ARGS` 硬编码传递 zlib 路径

**第三层**（真正的 gRPC CMake）：
- 从 GitHub 下载的 gRPC 源码的 CMakeLists.txt
- 期望通过 `-DZLIB_ROOT` 等变量找到 zlib
- 或者通过 `find_package(ZLIB)`

---

## ✅ 解决方案

### 方案 1：在第二层使用 find_package（推荐）

**原理**：
- 第一层（外层）继承了 TheRock 的 `CMAKE_PREFIX_PATH`
- 在第二层启动前，先用 `find_package(ZLIB)` 找到 zlib
- 然后将找到的信息传递给第三层

**实现**：

```cmake
# Line 58-77: 在子项目构建中使用 find_package
cmake_minimum_required(VERSION 3.25)
project(GRPC_BUILD)

include(ProcessorCount)
ProcessorCount(PAR_JOBS)

if(NOT PATCHELF)
  message(FATAL_ERROR "Missing PATCHELF from super-project")
endif()

# ✅ 使用 find_package 查找 zlib
# CMAKE_PREFIX_PATH 已由 RUNTIME_DEPS 机制自动设置
find_package(ZLIB REQUIRED CONFIG)

if(NOT ZLIB_FOUND)
  message(FATAL_ERROR "ZLIB not found. Please ensure therock-zlib is built first.")
endif()

# ✅ 获取 zlib 的信息
get_target_property(ZLIB_INCLUDE_DIR ZLIB::ZLIB INTERFACE_INCLUDE_DIRECTORIES)
get_target_property(ZLIB_LIBRARY ZLIB::ZLIB IMPORTED_LOCATION)
get_filename_component(ZLIB_ROOT "${ZLIB_LIBRARY}" DIRECTORY)
get_filename_component(ZLIB_ROOT "${ZLIB_ROOT}/.." ABSOLUTE)

message(STATUS "Found ZLIB via find_package()")
message(STATUS "  ZLIB_INCLUDE_DIR: ${ZLIB_INCLUDE_DIR}")
message(STATUS "  ZLIB_LIBRARY: ${ZLIB_LIBRARY}")
message(STATUS "  ZLIB_ROOT: ${ZLIB_ROOT}")

add_custom_target(
  build ALL
  # ... (其余保持不变)
  COMMAND
    "${CMAKE_COMMAND}"
      # ...
      "-DgRPC_ZLIB_PROVIDER=package"
      "-DZLIB_ROOT=${ZLIB_ROOT}"
      "-DZLIB_INCLUDE_DIR=${ZLIB_INCLUDE_DIR}"
      "-DZLIB_LIBRARY=${ZLIB_LIBRARY}"
      # ...
)
```

**优点**：
- ✅ 使用 `find_package()` 符合 CMake 最佳实践
- ✅ 依赖 `CMAKE_PREFIX_PATH` 而不是硬编码路径
- ✅ 利用 TheRock 的 RUNTIME_DEPS 机制
- ✅ 路径是动态查找的，不是硬编码的
- ✅ 最小改动，风险低

**缺点**：
- ⚠️ 仍然需要传递变量给第三层（因为有三层 CMake）
- ⚠️ 但这是必要的，因为第三层是独立的 CMake 进程

---

### 方案 2：传递 CMAKE_PREFIX_PATH 给第三层（更彻底）

**原理**：
- 将 TheRock 的 `CMAKE_PREFIX_PATH` 传递给第三层
- 让第三层的 gRPC CMake 自己 `find_package(ZLIB)`

**实现**：

```cmake
cmake_minimum_required(VERSION 3.25)
project(GRPC_BUILD)

# ✅ 检查 CMAKE_PREFIX_PATH 是否包含 zlib
message(STATUS "CMAKE_PREFIX_PATH: ${CMAKE_PREFIX_PATH}")

# ✅ 验证 zlib 可以被找到
find_package(ZLIB REQUIRED CONFIG)
message(STATUS "ZLIB found at: ${ZLIB_DIR}")

add_custom_target(
  build ALL
  COMMAND
    "${CMAKE_COMMAND}"
      "-G${CMAKE_GENERATOR}"
      "-S${CMAKE_CURRENT_BINARY_DIR}/s"
      "-B${CMAKE_CURRENT_BINARY_DIR}/b"
      # ...
      # ✅ 传递 CMAKE_PREFIX_PATH 而不是具体路径
      "-DCMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}"
      # ✅ 让 gRPC 自己 find_package(ZLIB)
      "-DgRPC_ZLIB_PROVIDER=package"
      # ❌ 不传递具体路径
      # "-DZLIB_ROOT=${ZLIB_ROOT}"
      # "-DZLIB_INCLUDE_DIR=${ZLIB_INCLUDE_DIR}"
      # "-DZLIB_LIBRARY=${ZLIB_LIBRARY}"
      # ...
)
```

**优点**：
- ✅✅ 完全依赖 `find_package()` 和 `CMAKE_PREFIX_PATH`
- ✅✅ 无任何硬编码路径
- ✅ 符合 CMake 现代最佳实践

**缺点**：
- ⚠️ 需要验证 gRPC 的 CMakeLists.txt 能否正确 `find_package(ZLIB)`
- ⚠️ 如果 gRPC 的 FindZLIB.cmake 行为不符合预期，可能失败

---

### 方案 3：混合方案（平衡风险）

**实现**：

```cmake
cmake_minimum_required(VERSION 3.25)
project(GRPC_BUILD)

# ✅ 使用 find_package 查找 zlib
find_package(ZLIB REQUIRED CONFIG)

# ✅ 获取 zlib 的根目录
get_target_property(ZLIB_LIBRARY ZLIB::ZLIB IMPORTED_LOCATION)
get_filename_component(ZLIB_LIB_DIR "${ZLIB_LIBRARY}" DIRECTORY)
get_filename_component(ZLIB_ROOT "${ZLIB_LIB_DIR}/.." ABSOLUTE)

message(STATUS "Found ZLIB via find_package()")
message(STATUS "  ZLIB_ROOT: ${ZLIB_ROOT}")
message(STATUS "  ZLIB_LIBRARY: ${ZLIB_LIBRARY}")

add_custom_target(
  build ALL
  COMMAND
    "${CMAKE_COMMAND}"
      # ...
      # ✅ 传递 CMAKE_PREFIX_PATH（让 gRPC 可以 find_package）
      "-DCMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}"
      # ✅ 同时传递具体路径（作为后备）
      "-DgRPC_ZLIB_PROVIDER=package"
      "-DZLIB_ROOT=${ZLIB_ROOT}"
      # ...
)
```

**优点**：
- ✅ 主要依赖 `find_package()` 和 `CMAKE_PREFIX_PATH`
- ✅ 保留具体路径作为后备
- ✅ 兼容性好，风险低

---

## 📊 与 RDC 的对比

| 方面 | RDC + gRPC | gRPC + zlib |
|------|-----------|-------------|
| **依赖声明** | `RUNTIME_DEPS: ${THEROCK_BUNDLED_GRPC}` | `RUNTIME_DEPS: therock-zlib` |
| **CMake 层数** | 1 层（直接 therock_subproject） | 3 层（外层 + 内层 + 真正的 gRPC） |
| **原始问题** | 硬编码 `GRPC_ROOT` | 硬编码 `ZLIB_ROOT` |
| **解决方案** | 删除硬编码，用 CMAKE_PREFIX_PATH | 也可以类似处理 |
| **复杂度** | 简单（1 层 CMake） | 复杂（3 层 CMake） |
| **完全解决** | ✅ 可以完全删除硬编码 | ⚠️ 受限于多层 CMake |

---

## 🎯 推荐方案

### 推荐：方案 1（使用 find_package，保留变量传递）

**理由**：
1. ✅ 符合 code reviewer 的要求："use find_package()"
2. ✅ 移除了硬编码路径的构造（`${THEROCK_BINARY_DIR}/third-party/...`）
3. ✅ 依赖 `CMAKE_PREFIX_PATH` 机制
4. ✅ 风险低，兼容性好
5. ✅ 与 TheRock 的依赖管理机制协同工作

**关键改进**：

**之前**：
```cmake
# ❌ 硬编码路径
set(ZLIB_ROOT "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/zlib/build/stage/lib/rocm_sysdeps")
```

**之后**：
```cmake
# ✅ 使用 find_package
find_package(ZLIB REQUIRED CONFIG)
# ✅ 从找到的 target 获取信息
get_target_property(ZLIB_LIBRARY ZLIB::ZLIB IMPORTED_LOCATION)
get_filename_component(ZLIB_ROOT ...)
```

---

## 💡 为什么需要传递变量给第三层？

**三层 CMake 的现实**：

```
Layer 1 (TheRock)
  ├── CMAKE_PREFIX_PATH 包含 zlib 路径 ✅
  └── 启动 Layer 2

Layer 2 (gRPC 外层, line 1-56)
  ├── 继承 CMAKE_PREFIX_PATH ✅
  ├── find_package(ZLIB) 可以找到 ✅
  └── 使用 add_custom_target + cmake 命令启动 Layer 3

Layer 3 (gRPC 内层, line 58+)
  ├── 这是一个 **新的独立 CMake 进程**！
  ├── **不自动继承** Layer 2 的 CMAKE_PREFIX_PATH ❌
  └── 需要通过 -D... 显式传递信息
      └── 这就是为什么需要 CMAKE_ARGS

Layer 4 (真正的 gRPC CMake)
  ├── 从 GitHub 下载的源码
  ├── 期望通过 -DZLIB_ROOT 或 CMAKE_PREFIX_PATH 找到 zlib
  └── 使用 find_package(ZLIB) 或 FindZLIB.cmake
```

**关键点**：
- Layer 3 是通过 `execute_process` 或 `COMMAND cmake ...` 启动的
- 这是一个**全新的 CMake 进程**，有独立的变量作用域
- 不会继承父进程的 CMake 变量（除非显式传递）
- 但是可以传递 `CMAKE_PREFIX_PATH` 环境变量或作为 `-D` 参数

---

## 🔍 Code Reviewer 关切的本质

**关切的核心**：
> "This is a big anti-pattern."

**为什么是 anti-pattern？**

1. **硬编码路径结构**：
   ```cmake
   "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/zlib/build/stage/lib/rocm_sysdeps"
   ```
   - 假设了特定的目录结构
   - 如果 zlib 的构建方式改变，这里会失败
   - 不可移植，不可重用

2. **绕过 CMake 的包管理**：
   - zlib 提供了 `ZLIBConfig.cmake`
   - 但没有使用 `find_package(ZLIB)`
   - 绕过了 CMake 的标准机制

3. **重复的依赖声明**：
   - 外层声明了 `RUNTIME_DEPS: therock-zlib` ✅
   - 内层又硬编码路径 ❌
   - 依赖关系被声明了两次

**正确的做法**：
- ✅ 外层声明 `RUNTIME_DEPS: therock-zlib`（已有）
- ✅ 内层使用 `find_package(ZLIB)`（需要改进）
- ✅ 依赖 `CMAKE_PREFIX_PATH` 自动查找（TheRock 机制）

---

## 📝 实施步骤

### Step 1: 修改 gRPC 的 CMakeLists.txt

删除硬编码，使用 find_package：

```cmake
# Line 69-76: 替换为
# Use find_package to locate zlib (provided by therock-zlib via RUNTIME_DEPS)
# CMAKE_PREFIX_PATH is automatically set to include zlib's stage directory
find_package(ZLIB REQUIRED CONFIG)

if(NOT TARGET ZLIB::ZLIB)
  message(FATAL_ERROR "ZLIB::ZLIB target not found. Please ensure therock-zlib is built first.")
endif()

# Extract zlib information from the imported target
get_target_property(ZLIB_INCLUDE_DIR ZLIB::ZLIB INTERFACE_INCLUDE_DIRECTORIES)
get_target_property(ZLIB_LIBRARY ZLIB::ZLIB IMPORTED_LOCATION)
# Get ZLIB_ROOT by going up from lib directory
get_filename_component(ZLIB_LIB_DIR "${ZLIB_LIBRARY}" DIRECTORY)
get_filename_component(ZLIB_ROOT "${ZLIB_LIB_DIR}/.." ABSOLUTE)

message(STATUS "Found ZLIB via find_package()")
message(STATUS "  ZLIB_ROOT: ${ZLIB_ROOT}")
message(STATUS "  ZLIB_INCLUDE_DIR: ${ZLIB_INCLUDE_DIR}")
message(STATUS "  ZLIB_LIBRARY: ${ZLIB_LIBRARY}")
```

### Step 2: （可选）移除 THEROCK_BINARY_DIR 传递

如果不再需要构造硬编码路径，可以考虑移除：

```cmake
# Line 21-26: 移除 THEROCK_BINARY_DIR
CMAKE_ARGS
  "-DSOURCE_DIR=${_source_dir}"
  "-DPATCHELF=${PATCHELF}"
  "-DTHEROCK_SOURCE_DIR=${THEROCK_SOURCE_DIR}"
  # "-DTHEROCK_BINARY_DIR=${THEROCK_BINARY_DIR}"  # ← 可以移除
  "-DPython3_EXECUTABLE=${Python3_EXECUTABLE}"
```

### Step 3: 测试

```bash
rm -rf build-3/third-party/sysdeps/linux/grpc/
rm -rf build-3/profiler/

amdgpu_families="gfx1151" \
BUILD_DIR="build-3" \
extra_cmake_options="-DTHEROCK_ENABLE_RDC=ON" \
python3 build_tools/github_actions/build_configure.py --manylinux

cmake --build build-3 --target therock-grpc -- -k 0
```

---

## ✅ 预期结果

### 配置日志应该显示：

```
-- Found ZLIB via find_package()
--   ZLIB_ROOT: /workspace/TheRock/build-3/third-party/sysdeps/linux/zlib/build/stage/lib/rocm_sysdeps
--   ZLIB_INCLUDE_DIR: /workspace/TheRock/build-3/.../include
--   ZLIB_LIBRARY: /workspace/TheRock/build-3/.../lib/librocm_sysdeps_z.so.1
```

**关键区别**：
- ❌ 之前：`set(ZLIB_ROOT "${THEROCK_BINARY_DIR}/third-party/...")`（硬编码）
- ✅ 之后：`find_package(ZLIB)` → 通过 CMAKE_PREFIX_PATH 找到（动态）

---

## 📋 Code Review 检查清单

在提交修改后，确认以下几点：

- [ ] 移除了硬编码的 `set(ZLIB_ROOT ...)`, `set(ZLIB_INCLUDE_DIR ...)`, `set(ZLIB_LIBRARY ...)`
- [ ] 使用了 `find_package(ZLIB REQUIRED CONFIG)`
- [ ] 依赖 `CMAKE_PREFIX_PATH` 机制（由 RUNTIME_DEPS 自动设置）
- [ ] 保留了 `RUNTIME_DEPS therock-zlib` 声明
- [ ] 构建成功，gRPC 正确链接 zlib
- [ ] 配置日志显示 "Found ZLIB via find_package()"

---

## 🎯 总结

**当前问题**：❌ 硬编码 zlib 路径
```cmake
set(ZLIB_ROOT "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/zlib/build/stage/lib/rocm_sysdeps")
```

**解决方案**：✅ 使用 find_package
```cmake
find_package(ZLIB REQUIRED CONFIG)
get_target_property(ZLIB_LIBRARY ZLIB::ZLIB IMPORTED_LOCATION)
```

**符合要求**：
- ✅ "correctly modeled dep on zlib" - 通过 RUNTIME_DEPS
- ✅ "use find_package()" - 使用 find_package(ZLIB)
- ✅ 不再是 "big anti-pattern"

**与 RDC/gRPC 修复的一致性**：
- 都是移除硬编码路径
- 都是使用 find_package()
- 都是依赖 CMAKE_PREFIX_PATH
- 体现了 TheRock 依赖管理的统一性

---

**分析日期**：2025-11-09  
**分析人**：AI Assistant  
**结论**：✅ 可以通过使用 `find_package(ZLIB)` 解决 code reviewer 的关切

