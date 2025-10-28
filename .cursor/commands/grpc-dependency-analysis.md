# gRPC 依赖问题分析

## Code Reviewer 的关切

### 问题 1: 硬编码路径
> "Any dependency should be picked up via find_package. There shouldn't be any hardcoded paths to any deps."

**当前实现（有问题）：**
```cmake
# profiler/CMakeLists.txt 第135行
set(_grpc_build_path "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps")

therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    "-DGRPC_ROOT=${_grpc_build_path}"  # ❌ 硬编码路径
    "-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin"  # ❌ 硬编码路径
)
```

**问题所在：**
- ❌ 硬编码了 gRPC 的构建路径
- ❌ 假设了特定的目录结构
- ❌ 不灵活，难以适配不同的构建环境
- ❌ 违反了 CMake 的最佳实践

### 问题 2: 包的职责边界
> "Furthermore, if gRPC is a separate package this package itself needs to install whatever is needed, it should not be done by RDC."

**当前实现（可能有问题）：**
```cmake
# RDC 的 CMakeLists.txt (第313-325行)
# Don't print grpc install because it floods the terminal
set(OLD_CMAKE_INSTALL_MESSAGE ${CMAKE_INSTALL_MESSAGE})
set(CMAKE_INSTALL_MESSAGE NEVER)

# Install gRPC package based on GRPC_ROOT variable
# This is needed for both rdcd(server) and rdci(client) targets
install(
    DIRECTORY ${GRPC_ROOT}/
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/rdc/grpc
    USE_SOURCE_PERMISSIONS
)

set(CMAKE_INSTALL_MESSAGE ${OLD_CMAKE_INSTALL_MESSAGE})
```

**问题所在：**
- ❌ RDC 负责安装 gRPC 文件（`install(DIRECTORY ${GRPC_ROOT}/ ...)`）
- ❌ 这应该是 gRPC 包自己的职责
- ❌ 违反了单一职责原则
- ❌ 使得 RDC 和 gRPC 的打包边界不清晰

## RDC 如何使用 gRPC

### RDC 的 CMakeLists.txt 实现
```cmake
# 第307-311行（当 BUILD_STANDALONE=ON 时）
if(BUILD_STANDALONE)
    # these packages are later used in server and client targets
    find_package(protobuf HINTS ${GRPC_ROOT} CONFIG REQUIRED)
    find_package(gRPC ${GRPC_DESIRED_VERSION} HINTS ${GRPC_ROOT} CONFIG REQUIRED)
    
    # ... 然后安装 gRPC 文件到 lib/rdc/grpc/
endif()
```

**RDC 的需求：**
1. 需要找到 protobuf 和 gRPC 的 CMake 配置文件
2. 需要 protoc 和 grpc_cpp_plugin 可执行文件（用于生成代码）
3. 需要 gRPC 的库文件和头文件

## TheRock 的依赖管理机制

### 系统依赖的构建方式

**third-party/sysdeps/linux/CMakeLists.txt：**
```cmake
add_subdirectory(grpc)  # 构建 gRPC

therock_provide_artifact(sysdeps
  SUBPROJECT_DEPS
    therock-grpc  # gRPC 作为 sysdeps artifact 的一部分
)
```

**TheRock 的依赖变量：**
```cmake
# 在 CMakeLists.txt 或相关的 cmake 文件中定义
THEROCK_BUNDLED_GRPC     # 表示 bundled gRPC 子项目
THEROCK_BUNDLED_ZLIB     # 表示 bundled zlib 子项目
THEROCK_BUNDLED_LIBCAP   # 表示 bundled libcap 子项目
```

### 依赖的传递方式

在 RDC 的声明中：
```cmake
RUNTIME_DEPS
  ROCR-Runtime
  amdsmi
  rocprofiler-sdk
  ${THEROCK_BUNDLED_LIBCAP}
  ${THEROCK_BUNDLED_ZLIB}
  ${THEROCK_BUNDLED_GRPC}  # ← gRPC 作为运行时依赖
```

这意味着：
- gRPC 会在 RDC 之前构建
- RDC 的 stage 目录会包含 gRPC 的文件
- **但是如何让 RDC 找到 gRPC？**

## 问题根源分析

### 为什么会有硬编码路径？

1. **RDC 的 find_package 需要 GRPC_ROOT hint**
   ```cmake
   find_package(gRPC HINTS ${GRPC_ROOT} CONFIG REQUIRED)
   ```

2. **TheRock 需要告诉 RDC 去哪里找 gRPC**
   - gRPC 构建在 `third-party/sysdeps/linux/grpc/build/stage/`
   - RDC 期望通过 GRPC_ROOT 变量得到这个路径
   - 因此 TheRock 硬编码了这个路径

3. **RDC 自己安装 gRPC 文件**
   ```cmake
   install(DIRECTORY ${GRPC_ROOT}/ DESTINATION lib/rdc/grpc ...)
   ```
   - RDC 将整个 gRPC 安装目录复制到自己的 lib/rdc/grpc/
   - 这样做是为了让 RDC 的运行时能找到 gRPC

### 为什么这样做是有问题的？

#### 问题 1: 硬编码路径的问题
```cmake
# ❌ 当前做法
set(_grpc_build_path "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps")
```

**问题：**
- 假设了固定的目录结构
- 不适用于系统安装的 gRPC
- 不适用于其他构建系统
- 难以在不同环境中复用

#### 问题 2: RDC 安装 gRPC 的问题
```cmake
# ❌ RDC 的 CMakeLists.txt
install(DIRECTORY ${GRPC_ROOT}/ DESTINATION lib/rdc/grpc ...)
```

**问题：**
- gRPC 应该作为独立包安装到 `lib/rocm_sysdeps/`
- RDC 应该依赖已安装的 gRPC，而不是自己安装
- 这导致 gRPC 被重复打包
- 包的职责边界不清晰

## 正确的做法

### 方案：使用 CMake Package Registry 机制

#### 步骤 1: gRPC 正确安装自己的配置文件

gRPC 应该安装到标准位置，并提供 CMake 配置文件：
```
lib/rocm_sysdeps/
  ├── lib/
  │   ├── libgrpc++.so
  │   └── ...
  ├── include/
  │   └── grpc/
  └── lib/cmake/
      ├── gRPC/
      │   └── gRPCConfig.cmake
      └── protobuf/
          └── protobufConfig.cmake
```

#### 步骤 2: RDC 使用标准的 find_package

**正确的 RDC 配置（在 profiler/CMakeLists.txt）：**
```cmake
therock_cmake_subproject_declare(rdc
  EXTERNAL_SOURCE_DIR "${THEROCK_ROCM_SYSTEMS_SOURCE_DIR}/projects/rdc"
  BACKGROUND_BUILD

  CMAKE_ARGS
    -DBUILD_PROFILER=ON
    -DBUILD_STANDALONE=ON
    -DBUILD_RUNTIME=ON
    -DBUILD_RVS=OFF
    -DBUILD_TESTS=ON
    -DHIP_PLATFORM=amd
    -DCMAKE_CXX_STANDARD=17
    # ✅ 让 CMake 使用 CMAKE_PREFIX_PATH 自然查找
    # 不需要 GRPC_ROOT 和 CMAKE_PROGRAM_PATH

  BUILD_DEPS
    amd-llvm

  RUNTIME_DEPS
    ROCR-Runtime
    amdsmi
    rocprofiler-sdk
    ${THEROCK_BUNDLED_LIBCAP}
    ${THEROCK_BUNDLED_ZLIB}
    ${THEROCK_BUNDLED_GRPC}  # ← 这会确保 gRPC 先构建

  INTERFACE_LINK_DIRS
    lib
)
```

**为什么这样可以工作？**

1. **${THEROCK_BUNDLED_GRPC} 在 RUNTIME_DEPS 中**
   - 确保 gRPC 在 RDC 之前构建
   - TheRock 的子项目系统会自动设置 CMAKE_PREFIX_PATH

2. **CMAKE_PREFIX_PATH 自动包含依赖项的 stage 目录**
   - TheRock 会将 gRPC 的 stage 目录添加到 CMAKE_PREFIX_PATH
   - CMake 会在这些路径中查找 *Config.cmake 文件

3. **RDC 的 find_package 可以自然找到 gRPC**
   ```cmake
   # RDC 的 CMakeLists.txt 可以简化为：
   find_package(protobuf CONFIG REQUIRED)
   find_package(gRPC ${GRPC_DESIRED_VERSION} CONFIG REQUIRED)
   # 不需要 HINTS ${GRPC_ROOT}
   ```

#### 步骤 3: 修改 RDC 的 CMakeLists.txt（如果需要）

**当前 RDC 的代码：**
```cmake
find_package(protobuf HINTS ${GRPC_ROOT} CONFIG REQUIRED)
find_package(gRPC ${GRPC_DESIRED_VERSION} HINTS ${GRPC_ROOT} CONFIG REQUIRED)

install(DIRECTORY ${GRPC_ROOT}/ DESTINATION ${CMAKE_INSTALL_LIBDIR}/rdc/grpc ...)
```

**改进方案：**
```cmake
# 选项 A: 让 GRPC_ROOT 可选
find_package(protobuf CONFIG REQUIRED)
find_package(gRPC ${GRPC_DESIRED_VERSION} CONFIG REQUIRED)

# 选项 B: 保留 GRPC_ROOT 但让它可选
if(GRPC_ROOT)
  find_package(protobuf HINTS ${GRPC_ROOT} CONFIG REQUIRED)
  find_package(gRPC ${GRPC_DESIRED_VERSION} HINTS ${GRPC_ROOT} CONFIG REQUIRED)
else()
  find_package(protobuf CONFIG REQUIRED)
  find_package(gRPC ${GRPC_DESIRED_VERSION} CONFIG REQUIRED)
endif()

# ❌ 移除这段 - gRPC 应该自己安装
# install(DIRECTORY ${GRPC_ROOT}/ ...)
```

**但是有个问题：**
- 如果移除 `install(DIRECTORY ${GRPC_ROOT}/ ...)`
- RDC 运行时如何找到 gRPC 的 .so 文件？

**解决方案：**
- gRPC 应该安装到 `lib/rocm_sysdeps/lib/`
- RDC 链接 gRPC 时使用 RPATH
- 运行时通过 RPATH 找到 `lib/rocm_sysdeps/lib/` 中的 gRPC

## TheRock 需要做的改动

### 1. 移除硬编码路径（profiler/CMakeLists.txt）

**移除这些行：**
```cmake
# ❌ 删除
set(_grpc_build_path "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps")

# ❌ 删除 CMAKE_ARGS 中的：
"-DGRPC_ROOT=${_grpc_build_path}"
-DGRPC_DESIRED_VERSION=1.76.0
"-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin"
```

**保留：**
```cmake
RUNTIME_DEPS
  ${THEROCK_BUNDLED_GRPC}  # ✅ 保留这个依赖声明
```

### 2. 确保 TheRock 的子项目系统正确设置 CMAKE_PREFIX_PATH

这应该已经由 TheRock 的构建系统自动处理。

### 3. 可能需要修改 RDC 的 CMakeLists.txt

**最小改动方案（如果 RDC 是外部项目）：**
```cmake
# 在 profiler/CMakeLists.txt 中
therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    # 不传递 GRPC_ROOT，让 find_package 自然查找
    # 或者传递 CMAKE_PREFIX_PATH（TheRock 应该自动处理）
)
```

**如果需要修改 RDC 源码：**
- 移除 `install(DIRECTORY ${GRPC_ROOT}/ ...)` 这段代码
- 改为依赖已安装的 gRPC
- 使用 RPATH 找到 gRPC 库

## 实例说明

### 当前流程（有问题）

```
1. TheRock 构建 gRPC
   → 安装到 third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps/

2. TheRock 配置 RDC
   → 硬编码 GRPC_ROOT = "third-party/.../rocm_sysdeps"
   → 传递给 RDC 的 CMake

3. RDC 的 CMake
   → 使用 GRPC_ROOT 作为 hint 查找 gRPC
   → 找到 gRPC 的 Config.cmake
   → 链接 gRPC 库
   → install(DIRECTORY ${GRPC_ROOT}/ ...)  ← ❌ RDC 安装 gRPC

4. 结果
   → gRPC 文件被复制到 profiler/rdc/stage/lib/rdc/grpc/
   → gRPC 也在 third-party/sysdeps/.../
   → 重复打包
```

### 改进后的流程（正确）

```
1. TheRock 构建 gRPC
   → 安装到 build/third-party/sysdeps/.../stage/lib/rocm_sysdeps/
   → 提供 gRPCConfig.cmake

2. TheRock 配置 RDC
   → 设置 CMAKE_PREFIX_PATH 包含 gRPC 的 stage 目录
   → ✅ 不传递硬编码路径
   → RUNTIME_DEPS 包含 ${THEROCK_BUNDLED_GRPC}

3. RDC 的 CMake
   → find_package(gRPC CONFIG REQUIRED)
   → CMake 通过 CMAKE_PREFIX_PATH 找到 gRPCConfig.cmake
   → 链接 gRPC 库（使用 RPATH 指向 lib/rocm_sysdeps/）
   → ✅ 不安装 gRPC（gRPC 自己负责）

4. 结果
   → gRPC 只在 lib/rocm_sysdeps/ 中
   → RDC 通过 RPATH 运行时链接
   → 职责清晰，无重复
```

## 总结

### Code Reviewer 的关切是正确的

1. ✅ **不应该硬编码路径**
   - 应该让 CMake 的 find_package 机制工作
   - 通过 CMAKE_PREFIX_PATH 和依赖关系自然找到

2. ✅ **gRPC 应该自己安装自己**
   - gRPC 包应该安装到 lib/rocm_sysdeps/
   - RDC 应该依赖并链接 gRPC，而不是安装它
   - 这是包职责分离的基本原则

### 需要改动的内容

#### 在 TheRock 中（最小改动）：
```cmake
# profiler/CMakeLists.txt

# ❌ 删除
set(_grpc_build_path "...")

therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    -DBUILD_PROFILER=ON
    -DBUILD_STANDALONE=ON
    # ... 其他参数 ...
    # ❌ 删除这些
    # "-DGRPC_ROOT=${_grpc_build_path}"
    # -DGRPC_DESIRED_VERSION=1.76.0
    # "-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin"

  RUNTIME_DEPS
    ${THEROCK_BUNDLED_GRPC}  # ✅ 保留
)
```

#### 可能需要在 RDC 中（如果我们可以修改）：
- 移除 `install(DIRECTORY ${GRPC_ROOT}/ ...)` 
- 让 GRPC_ROOT 成为可选参数
- 依赖 CMAKE_PREFIX_PATH 找到 gRPC

### 风险评估

**如果只改 TheRock（不改 RDC）：**
- ⚠️ RDC 的 find_package 可能失败（如果 CMAKE_PREFIX_PATH 没有正确设置）
- ⚠️ 需要验证 TheRock 的子项目系统是否自动设置 CMAKE_PREFIX_PATH

**如果同时改 RDC：**
- ✅ 彻底解决问题
- ⚠️ 需要修改外部项目（rocm-systems/projects/rdc）
- ⚠️ 需要协调多个团队

### 建议

**选项 1：最小改动（推荐先尝试）**
1. 从 profiler/CMakeLists.txt 移除硬编码路径
2. 保留 RUNTIME_DEPS 中的 ${THEROCK_BUNDLED_GRPC}
3. 测试是否能工作
4. 如果失败，分析原因

**选项 2：完整解决（如果选项1不够）**
1. 改动 TheRock（如上）
2. 向 RDC 团队提出改进建议
3. 让 GRPC_ROOT 可选
4. 移除 RDC 安装 gRPC 的逻辑

