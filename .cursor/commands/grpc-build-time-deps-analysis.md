# gRPC 构建时依赖完整分析

## 重要发现：gRPC 既是运行时依赖，也是构建时依赖

你的问题非常关键！让我重新完整分析。

### gRPC 作为 RDC 的双重角色

#### 1. 运行时依赖（Runtime Dependency）
```bash
librdc.so
├── 链接 libgrpc++.so     # 运行时需要
├── 链接 libprotobuf.so   # 运行时需要
└── RPATH: $ORIGIN/../rocm_sysdeps/lib
```

**用途：**
- RDC 运行时需要链接 gRPC 的共享库
- 通过 RPATH 在运行时找到这些 .so 文件

#### 2. 构建时依赖（Build-time Dependency）
```bash
RDC 构建过程需要：
├── protoc               # Protocol Buffer 编译器（生成 .pb.h/.pb.cc）
├── grpc_cpp_plugin      # gRPC C++ 插件（生成 gRPC service 代码）
├── libgrpc++.so         # 编译时链接
├── 头文件 include/grpc/ # 编译时包含
└── gRPCConfig.cmake     # CMake 配置文件
```

**用途：**
- **protoc**: 将 .proto 文件编译成 C++ 代码（.pb.h/.pb.cc）
- **grpc_cpp_plugin**: 生成 gRPC 的 service stub 代码
- **头文件**: 编译 RDC 源码时需要 #include <grpc/...>
- **gRPCConfig.cmake**: find_package(gRPC) 需要找到这个文件

### 当前实现的完整流程

#### profiler/CMakeLists.txt（TheRock 层）
```cmake
# 第135行
set(_grpc_build_path "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps")

therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    "-DGRPC_ROOT=${_grpc_build_path}"
    -DGRPC_DESIRED_VERSION=1.76.0
    "-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin"  # ← 关键：帮助找到 protoc/grpc_cpp_plugin

  BUILD_DEPS
    amd-llvm

  RUNTIME_DEPS
    ${THEROCK_BUNDLED_GRPC}  # ← 确保 gRPC 先构建
)
```

**CMAKE_PROGRAM_PATH 的作用：**
- 告诉 CMake 在这个路径中查找可执行文件
- 特别是 `protoc` 和 `grpc_cpp_plugin`
- 这些工具在 RDC 的 CMake 配置阶段就需要运行

#### RDC 的 CMakeLists.txt（RDC 层）
```cmake
# 第310-311行
find_package(protobuf HINTS ${GRPC_ROOT} CONFIG REQUIRED)
find_package(gRPC ${GRPC_DESIRED_VERSION} HINTS ${GRPC_ROOT} CONFIG REQUIRED)
```

**find_package 做了什么：**
1. 查找 `gRPCConfig.cmake` 和 `protobufConfig.cmake`
2. 导入 gRPC 和 protobuf 的库和工具
3. 设置变量（如 `gRPC_CPP_PLUGIN_EXECUTABLE`, `Protobuf_PROTOC_EXECUTABLE`）
4. 这些变量被 RDC 的 server/ 和 rdci/ 子目录使用

### 验证：gRPC 安装了哪些工具

```bash
$ ls build-3/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps/bin/
grpc_cpp_plugin         # ✅ gRPC C++ 插件
protoc -> protoc-31.1.0 # ✅ Protocol Buffer 编译器
protoc-31.1.0
protoc-gen-upb
protoc-gen-upb-31.1.0
protoc-gen-upbdefs
protoc-gen-upbdefs-31.1.0
```

**关键发现：**
- ✅ gRPC 确实安装了 `protoc` 和 `grpc_cpp_plugin`
- ✅ 这些工具在 `lib/rocm_sysdeps/bin/` 目录下

### gRPC 的 CMake 配置文件

#### gRPCConfig.cmake 做了什么

```cmake
# build-3/.../lib/cmake/grpc/gRPCConfig.cmake 会：
1. 导入 gRPC 的库（gRPC::grpc++）
2. 导入工具（gRPC::grpc_cpp_plugin）
3. 设置变量指向这些工具的位置
```

#### 关键问题：工具是如何被找到的？

**方式 1: 通过 CMake target（推荐）**
```cmake
# gRPCConfig.cmake 定义了：
add_executable(gRPC::grpc_cpp_plugin IMPORTED)
set_target_properties(gRPC::grpc_cpp_plugin PROPERTIES
  IMPORTED_LOCATION "${_IMPORT_PREFIX}/bin/grpc_cpp_plugin"
)
```

**方式 2: 通过 CMAKE_PROGRAM_PATH（当前使用）**
```cmake
# TheRock 设置：
CMAKE_PROGRAM_PATH = .../rocm_sysdeps/bin

# RDC 的子目录使用：
find_program(GRPC_CPP_PLUGIN grpc_cpp_plugin)
# 或者直接使用 ${gRPC_CPP_PLUGIN_EXECUTABLE}
```

### 问题重述：如果删除 CMAKE_PROGRAM_PATH 会怎样？

#### 情况 A: gRPCConfig.cmake 正确设置了工具路径

```cmake
# 如果 gRPCConfig.cmake 做了：
set(gRPC_CPP_PLUGIN_EXECUTABLE "${_IMPORT_PREFIX}/bin/grpc_cpp_plugin" CACHE FILEPATH "gRPC C++ plugin")

# 那么 RDC 可以这样使用：
protobuf_generate(TARGET my_target ...)
grpc_generate(TARGET my_target PLUGIN grpc_cpp_plugin ...)
# 或者：
add_custom_command(COMMAND ${gRPC_CPP_PLUGIN_EXECUTABLE} ...)
```

**结论：** ✅ 不需要 CMAKE_PROGRAM_PATH

#### 情况 B: RDC 使用 find_program() 查找工具

```cmake
# 如果 RDC 代码中有：
find_program(GRPC_CPP_PLUGIN grpc_cpp_plugin)

# 那么 CMake 会在这些地方查找：
1. CMAKE_PROGRAM_PATH（我们要删除的）
2. PATH 环境变量（系统路径）
3. CMAKE_PREFIX_PATH/bin/（如果设置）
```

**结论：** ⚠️ 可能需要 CMAKE_PROGRAM_PATH 或 CMAKE_PREFIX_PATH

### 关键检查：RDC 如何使用 protoc 和 grpc_cpp_plugin

#### 检查 RDC 的 server/rdci 子目录

RDC 的 standalone 模式下：
- `server/` 目录：实现 gRPC server
- `rdci/` 目录：实现 gRPC client

这些目录的 CMakeLists.txt 需要：
1. 将 .proto 文件编译成 .pb.cc/.pb.h
2. 生成 gRPC service stub 代码

**典型的使用方式：**
```cmake
# 方式 1: 使用 protobuf_generate_cpp()
protobuf_generate_cpp(PROTO_SRCS PROTO_HDRS ${PROTO_FILES})

# 方式 2: 使用 grpc_generate_cpp()（如果 gRPC 提供）
grpc_generate_cpp(GRPC_SRCS GRPC_HDRS ${PROTO_FILES})

# 方式 3: 直接使用 add_custom_command
add_custom_command(
  OUTPUT ${PROTO_SRCS} ${PROTO_HDRS}
  COMMAND ${PROTOBUF_PROTOC_EXECUTABLE}
    --cpp_out=${CMAKE_CURRENT_BINARY_DIR}
    --plugin=protoc-gen-grpc=${gRPC_CPP_PLUGIN_EXECUTABLE}
    --grpc_out=${CMAKE_CURRENT_BINARY_DIR}
    ${PROTO_FILES}
)
```

### CMAKE_PREFIX_PATH vs CMAKE_PROGRAM_PATH

#### CMAKE_PREFIX_PATH
```cmake
# TheRock 已经设置（通过 RUNTIME_DEPS）
CMAKE_PREFIX_PATH = build/.../grpc/build/stage

# CMake 查找规则：
find_package(gRPC) → 在 CMAKE_PREFIX_PATH/lib/cmake/grpc/ 中查找
find_program(protoc) → 在 CMAKE_PREFIX_PATH/bin/ 中查找 ❓
```

**问题：** CMAKE_PREFIX_PATH 对 find_program() 的支持取决于 CMake 版本和配置

#### CMAKE_PROGRAM_PATH（显式指定）
```cmake
# 当前 TheRock 的做法
CMAKE_PROGRAM_PATH = .../rocm_sysdeps/bin

# CMake 查找规则：
find_program(protoc) → 优先在 CMAKE_PROGRAM_PATH 中查找 ✅
```

**优点：** 明确告诉 CMake 工具的位置

### 重新评估：是否应该删除硬编码路径

#### 分析 1: GRPC_ROOT 的必要性

**当前：**
```cmake
"-DGRPC_ROOT=${_grpc_build_path}"
```

**问题：**
- ❌ 硬编码路径
- ❌ 假设特定目录结构

**解决方案：**
```cmake
# 不传递 GRPC_ROOT，依赖 CMAKE_PREFIX_PATH
# TheRock 已经通过 RUNTIME_DEPS 设置了 CMAKE_PREFIX_PATH
```

**可行性：** ✅ 高（gRPCConfig.cmake 会在 CMAKE_PREFIX_PATH 中找到）

#### 分析 2: CMAKE_PROGRAM_PATH 的必要性

**当前：**
```cmake
"-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin"
```

**问题：**
- ❌ 硬编码路径
- ⚠️ 但可能确实需要帮助 find_program() 找到工具

**解决方案选项：**

**选项 1: 完全依赖 CMAKE_PREFIX_PATH**
```cmake
# 不传递 CMAKE_PROGRAM_PATH
# 依赖 CMake 在 CMAKE_PREFIX_PATH/bin/ 中查找
```

**可行性：** ⚠️ 中等
- CMake 3.25+ 应该支持在 CMAKE_PREFIX_PATH/bin/ 中查找
- 需要测试验证

**选项 2: 使用相对路径（更灵活）**
```cmake
# 基于 gRPCConfig.cmake 的位置推导 bin/ 路径
# 这通常由 gRPCConfig.cmake 自己处理
```

**可行性：** ✅ 高（如果 gRPCConfig.cmake 正确设置）

**选项 3: 传递非硬编码的 CMAKE_PROGRAM_PATH**
```cmake
# 使用 THEROCK_BUNDLED_GRPC 提供的路径信息
# 而不是硬编码字符串
```

**可行性：** ✅ 中等（需要修改 TheRock 的依赖系统）

### 实际测试需要验证的点

#### 测试 1: 删除 GRPC_ROOT
```cmake
# 修改 profiler/CMakeLists.txt
therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    # 不传递 GRPC_ROOT
  RUNTIME_DEPS
    ${THEROCK_BUNDLED_GRPC}
)
```

**预期结果：**
- ✅ find_package(gRPC) 应该能通过 CMAKE_PREFIX_PATH 找到
- ✅ find_package(protobuf) 应该能通过 CMAKE_PREFIX_PATH 找到

#### 测试 2: 删除 CMAKE_PROGRAM_PATH
```cmake
# 修改 profiler/CMakeLists.txt
therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    # 不传递 CMAKE_PROGRAM_PATH
  RUNTIME_DEPS
    ${THEROCK_BUNDLED_GRPC}
)
```

**可能的结果：**
- ❓ 如果 gRPCConfig.cmake 设置了 gRPC_CPP_PLUGIN_EXECUTABLE
  → ✅ 应该能工作
- ❓ 如果 RDC 使用 find_program() 且没有正确的搜索路径
  → ❌ 可能失败

### Code Reviewer 的关切在双重依赖下的重新评估

#### 关切 1: 硬编码路径
> "Any dependency should be picked up via find_package."

**分析：**
- ✅ **对于库和头文件**：完全正确，应该通过 find_package(gRPC) 找到
- ⚠️ **对于构建工具**：也应该通过 find_package 提供的变量或 CMAKE_PREFIX_PATH 找到
- ❌ **硬编码路径**：无论如何都不应该有

**结论：** 删除 `GRPC_ROOT=${_grpc_build_path}` 是正确的

#### 关切 2: 包职责
> "gRPC should install whatever is needed, not RDC."

**分析：**
- ✅ gRPC 已经正确安装了所有需要的东西：
  - ✅ 库文件（lib/libgrpc++.so）
  - ✅ 头文件（include/grpc/）
  - ✅ 工具（bin/protoc, bin/grpc_cpp_plugin）
  - ✅ CMake 配置（lib/cmake/grpc/gRPCConfig.cmake）
- ❌ RDC 不应该再安装一份 gRPC

**结论：** 需要修改 RDC 的 CMakeLists.txt 移除 `install(DIRECTORY ${GRPC_ROOT}/ ...)`

### CMAKE_PROGRAM_PATH 的特殊情况

#### 为什么可能需要它？

**场景：** RDC 的构建脚本（可能在 server/CMakeLists.txt 中）使用了：
```cmake
find_program(PROTOC_EXECUTABLE protoc)
find_program(GRPC_CPP_PLUGIN grpc_cpp_plugin)
```

而 CMake 可能不会自动在 CMAKE_PREFIX_PATH/bin/ 中查找（取决于版本和配置）。

#### 更好的解决方案：让 gRPCConfig.cmake 提供变量

```cmake
# gRPCConfig.cmake 应该设置：
set(Protobuf_PROTOC_EXECUTABLE "${_IMPORT_PREFIX}/bin/protoc")
set(gRPC_CPP_PLUGIN_EXECUTABLE "${_IMPORT_PREFIX}/bin/grpc_cpp_plugin")
```

然后 RDC 直接使用这些变量，而不是 find_program()。

### 最终建议（修正版）

#### 推荐方案：渐进式改进

**步骤 1: 删除 GRPC_ROOT（最安全）**
```cmake
# profiler/CMakeLists.txt
therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    -DBUILD_PROFILER=ON
    # ... 其他参数 ...
    # ❌ 删除
    # "-DGRPC_ROOT=${_grpc_build_path}"
    # -DGRPC_DESIRED_VERSION=1.76.0
    # ✅ 保留（暂时）
    "-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin"

  RUNTIME_DEPS
    ${THEROCK_BUNDLED_GRPC}  # ✅ 保留
)
```

**理由：**
- find_package() 应该能通过 CMAKE_PREFIX_PATH 找到 gRPCConfig.cmake
- 保留 CMAKE_PROGRAM_PATH 确保构建工具能被找到（安全起见）

**步骤 2: 测试并可能删除 CMAKE_PROGRAM_PATH**

构建测试成功后，尝试：
```cmake
therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    # 全部删除硬编码路径

  RUNTIME_DEPS
    ${THEROCK_BUNDLED_GRPC}
)
```

**测试：** 看 RDC 的配置阶段是否能找到 protoc 和 grpc_cpp_plugin

**步骤 3: 如果步骤 2 失败，使用更好的方案**

```cmake
# 选项 A: 让 TheRock 从 gRPC 的依赖信息中获取 bin 路径
# 而不是硬编码

# 选项 B: 修改 RDC 的 CMakeLists.txt，使用 gRPCConfig.cmake 提供的变量
# 而不是 find_program()
```

### 关于 BUILD_DEPS vs RUNTIME_DEPS

你提到 gRPC 既是构建依赖也是运行时依赖。在 TheRock 中：

```cmake
BUILD_DEPS
  amd-llvm  # 只在构建时需要

RUNTIME_DEPS
  ${THEROCK_BUNDLED_GRPC}  # 构建时和运行时都需要
```

**问题：** 为什么 gRPC 在 RUNTIME_DEPS 而不是 BUILD_DEPS？

**答案：** 
- RUNTIME_DEPS 意味着：
  1. 构建时需要（链接）
  2. 运行时需要（动态链接）
  3. 安装时需要打包在一起

- BUILD_DEPS 意味着：
  1. 只在构建时需要
  2. 运行时不需要
  3. 安装时不需要打包

对于 gRPC，RDC 运行时需要 libgrpc++.so，所以必须在 RUNTIME_DEPS。

**构建工具的问题：**
- protoc 和 grpc_cpp_plugin 只在构建时需要
- 但它们是 gRPC 包的一部分
- 通过 RUNTIME_DEPS 依赖 gRPC，这些工具会被构建
- 通过 CMAKE_PREFIX_PATH 或 CMAKE_PROGRAM_PATH，这些工具会被找到

### 总结

**你的问题是对的！** gRPC 确实既是运行时依赖也是构建时依赖：

1. **运行时依赖：**
   - libgrpc++.so 等共享库
   - 通过 RUNTIME_DEPS 处理 ✅

2. **构建时依赖：**
   - protoc, grpc_cpp_plugin 等工具
   - gRPCConfig.cmake
   - 头文件
   - 通过 find_package(gRPC) + CMAKE_PREFIX_PATH 处理 ✅
   - CMAKE_PROGRAM_PATH 是为了帮助找到工具 ⚠️

**修正后的建议：**

1. **必须删除 GRPC_ROOT** - 这是硬编码，违反最佳实践
2. **CMAKE_PROGRAM_PATH 可以暂时保留** - 需要验证删除后是否工作
3. **最终目标** - 全部依赖 CMAKE_PREFIX_PATH 和 gRPCConfig.cmake

你同意这个渐进式方案吗？

