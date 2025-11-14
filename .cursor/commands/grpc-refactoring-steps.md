# gRPC 依赖重构 - 混合方案实施指南

## 背景

Code reviewer 指出两个问题：
1. 不应该硬编码依赖路径（应该通过 find_package）
2. gRPC 应该自己安装自己（RDC 不应该重复安装 gRPC）

由于 gRPC 既是运行时依赖（链接库），也是构建时依赖（protoc/grpc_cpp_plugin 工具），
我们采用**混合方案**分步骤验证和改进。

## 📋 实施步骤

### ✅ 步骤 1：保守方案（已完成）

#### 改动内容

**删除：**
- ❌ `-DGRPC_ROOT=${_grpc_build_path}` - 硬编码的 gRPC 根路径
- ❌ `-DGRPC_DESIRED_VERSION=1.76.0` - 版本约束（应由 find_package 处理）

**保留：**
- ✅ `-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin` - 帮助找到构建工具
- ✅ `${THEROCK_BUNDLED_GRPC}` 在 RUNTIME_DEPS 中

#### 代码变化

**之前：**
```cmake
set(_grpc_build_path "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps")

therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    -DBUILD_PROFILER=ON
    -DBUILD_STANDALONE=ON
    -DBUILD_RUNTIME=ON
    -DBUILD_RVS=OFF
    -DBUILD_TESTS=ON
    -DHIP_PLATFORM=amd
    -DCMAKE_CXX_STANDARD=17
    "-DGRPC_ROOT=${_grpc_build_path}"              # ❌ 删除
    -DGRPC_DESIRED_VERSION=1.76.0                   # ❌ 删除
    "-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin" # ✅ 保留

  RUNTIME_DEPS
    ${THEROCK_BUNDLED_GRPC}  # ✅ 保留
)
```

**之后：**
```cmake
# 添加了详细注释说明机制
set(_grpc_build_path "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps")

therock_cmake_subproject_declare(rdc
  CMAKE_ARGS
    -DBUILD_PROFILER=ON
    -DBUILD_STANDALONE=ON
    -DBUILD_RUNTIME=ON
    -DBUILD_RVS=OFF
    -DBUILD_TESTS=ON
    -DHIP_PLATFORM=amd
    -DCMAKE_CXX_STANDARD=17
    # 只保留构建工具路径
    "-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin"

  RUNTIME_DEPS
    ${THEROCK_BUNDLED_GRPC}
)
```

#### 工作原理

1. **RUNTIME_DEPS 中的 ${THEROCK_BUNDLED_GRPC}**
   - TheRock 确保 gRPC 在 RDC 之前构建
   - TheRock 自动将 gRPC 的 stage 目录添加到 CMAKE_PREFIX_PATH
   - CMAKE_PREFIX_PATH ≈ `build/third-party/sysdeps/linux/grpc/build/stage`

2. **RDC 的 find_package() 调用**
   ```cmake
   # RDC 的 CMakeLists.txt (第310-311行)
   find_package(protobuf HINTS ${GRPC_ROOT} CONFIG REQUIRED)
   find_package(gRPC ${GRPC_DESIRED_VERSION} HINTS ${GRPC_ROOT} CONFIG REQUIRED)
   ```
   
   **行为变化：**
   - **之前**：使用 `HINTS ${GRPC_ROOT}` (硬编码路径)
   - **之后**：`GRPC_ROOT` 未定义，CMake 回退到使用 CMAKE_PREFIX_PATH
   - **结果**：在 `CMAKE_PREFIX_PATH/lib/rocm_sysdeps/lib/cmake/grpc/` 中找到 gRPCConfig.cmake ✅

3. **CMAKE_PROGRAM_PATH 的作用**
   ```cmake
   "-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin"
   ```
   
   **目的：**
   - 帮助 find_program() 找到 `protoc` 和 `grpc_cpp_plugin`
   - 这些工具在 RDC 的代码生成阶段需要
   - 暂时保留作为后备方案

#### 预期结果

✅ **应该成功，因为：**
- gRPCConfig.cmake 会在 CMAKE_PREFIX_PATH 中找到
- protobuf 的配置文件也会在 CMAKE_PREFIX_PATH 中找到
- 构建工具通过 CMAKE_PROGRAM_PATH 能被找到

⚠️ **可能的问题：**
- RDC 可能对 GRPC_ROOT 有显式检查或依赖
- 如果出现错误，检查 RDC 的配置日志

### 🔄 步骤 2：测试步骤 1

#### 清理并重新构建

```bash
# 1. 清理之前的构建
rm -rf build-3/

# 2. 重新配置
amdgpu_families="gfx1151" \
package_version="7.10.0.dev0+b121875e7047a9df1558ce859f999ec8e1df84fb" \
BUILD_DIR="build-3" \
extra_cmake_options="-DTHEROCK_ENABLE_MATH_LIBS=OFF \
                     -DTHEROCK_ENABLE_ML_LIBS=OFF \
                     -DTHEROCK_ENABLE_RCCL=OFF \
                     -DTHEROCK_ENABLE_RDC=ON" \
python3 build_tools/github_actions/build_configure.py --manylinux

# 3. 检查配置日志
tail -100 build-3/logs/rdc_configure.log
```

#### 预期的成功标志

在 `build-3/logs/rdc_configure.log` 中应该看到：

```
-- Found protobuf: <path to protobufConfig.cmake>
-- Found gRPC: <path to gRPCConfig.cmake>
-- Configuring done
-- Generating done
```

#### 如果失败

查找错误信息：
```bash
grep -i "could not find\|error" build-3/logs/rdc_configure.log
```

**常见错误 1: 找不到 gRPC**
```
CMake Error: Could not find a package configuration file provided by "gRPC"
```

**诊断：**
- 检查 CMAKE_PREFIX_PATH 是否包含 gRPC 的 stage 目录
- 检查 gRPCConfig.cmake 是否存在

**常见错误 2: 找不到工具**
```
CMake Error: Could not find protoc
```

**诊断：**
- CMAKE_PROGRAM_PATH 可能没有生效
- 工具可能不在预期位置

### ⏭️ 步骤 3：激进方案（待测试）

如果步骤 1 成功，尝试删除 CMAKE_PROGRAM_PATH：

#### 改动内容

**删除：**
```cmake
# ❌ 完全删除这些
set(_grpc_build_path "...")
"-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin"
```

**最终代码：**
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
    # ✅ 不传递任何硬编码路径

  BUILD_DEPS
    amd-llvm

  RUNTIME_DEPS
    ROCR-Runtime
    amdsmi
    rocprofiler-sdk
    ${THEROCK_BUNDLED_LIBCAP}
    ${THEROCK_BUNDLED_ZLIB}
    ${THEROCK_BUNDLED_GRPC}  # 依赖系统处理一切

  INTERFACE_LINK_DIRS
    lib
)
```

#### 工作原理

**依赖 gRPCConfig.cmake 提供工具路径：**

```cmake
# gRPCPluginTargets-release.cmake 已经定义了：
add_executable(gRPC::grpc_cpp_plugin IMPORTED)
set_target_properties(gRPC::grpc_cpp_plugin PROPERTIES
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/bin/grpc_cpp_plugin"
)
```

**如果 RDC 的代码使用：**
```cmake
# 方式 1: 直接使用 target
grpc_generate(
  PLUGIN gRPC::grpc_cpp_plugin  # ← CMake target
  ...
)

# 方式 2: 使用 CMake 提供的变量
set(GRPC_CPP_PLUGIN_EXECUTABLE $<TARGET_FILE:gRPC::grpc_cpp_plugin>)
```

那么就不需要 CMAKE_PROGRAM_PATH。

#### 测试步骤 3

```bash
# 1. 清理
rm -rf build-3/

# 2. 重新配置（和步骤2相同的命令）
amdgpu_families="gfx1151" \
package_version="7.10.0.dev0+b121875e7047a9df1558ce859f999ec8e1df84fb" \
BUILD_DIR="build-3" \
extra_cmake_options="-DTHEROCK_ENABLE_MATH_LIBS=OFF \
                     -DTHEROCK_ENABLE_ML_LIBS=OFF \
                     -DTHEROCK_ENABLE_RCCL=OFF \
                     -DTHEROCK_ENABLE_RDC=ON" \
python3 build_tools/github_actions/build_configure.py --manylinux

# 3. 检查结果
tail -100 build-3/logs/rdc_configure.log
```

#### 预期结果

✅ **理想情况：** 完全成功，证明 gRPCConfig.cmake 已经提供了所有必要信息

⚠️ **可能失败：** RDC 的实现依赖 find_program() 而不是 CMake target

## 🔍 故障排查指南

### 问题 1: 找不到 gRPCConfig.cmake

**症状：**
```
CMake Error: Could not find a package configuration file provided by "gRPC"
```

**检查：**
```bash
# 1. 检查 gRPC 是否构建
ls build-3/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps/lib/cmake/grpc/

# 2. 检查 CMAKE_PREFIX_PATH 设置
grep CMAKE_PREFIX_PATH build-3/logs/rdc_configure.log
```

**原因：**
- gRPC 没有被构建（依赖关系问题）
- CMAKE_PREFIX_PATH 没有被正确设置

**解决：**
- 确认 ${THEROCK_BUNDLED_GRPC} 在 RUNTIME_DEPS 中
- 检查 TheRock 的依赖系统是否正常工作

### 问题 2: 找不到 protoc 或 grpc_cpp_plugin

**症状（步骤 3）：**
```
CMake Error: Could not find protoc
```

**检查：**
```bash
# 1. 工具是否存在
ls build-3/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps/bin/

# 2. RDC 如何查找工具
grep "find_program.*protoc\|grpc_cpp_plugin" rocm-systems/projects/rdc/ -r
```

**原因：**
- RDC 使用 find_program() 而不是 CMake target
- CMAKE_PROGRAM_PATH 不够用

**解决方案：**
- 保留步骤 1 的实现（使用 CMAKE_PROGRAM_PATH）
- 或者向 RDC 团队报告，建议使用 gRPC::grpc_cpp_plugin target

### 问题 3: RDC 显式依赖 GRPC_ROOT

**症状：**
```
CMake Error: GRPC_ROOT is not defined
```

**检查：**
```bash
grep "GRPC_ROOT" rocm-systems/projects/rdc/CMakeLists.txt
```

**原因：**
- RDC 的代码中有 `if(NOT GRPC_ROOT)` 之类的检查

**解决方案：**
- 回退到传递 GRPC_ROOT（但使用变量而非硬编码）
- 或者修改 RDC 的 CMakeLists.txt 让 GRPC_ROOT 可选

## 📊 对比表

| 方面 | 原始实现 | 步骤1（保守） | 步骤3（激进） |
|------|---------|--------------|--------------|
| **GRPC_ROOT** | ❌ 硬编码 | ✅ 删除 | ✅ 删除 |
| **GRPC_VERSION** | ❌ 硬编码 | ✅ 删除 | ✅ 删除 |
| **CMAKE_PROGRAM_PATH** | ❌ 硬编码 | ⚠️ 保留硬编码 | ✅ 删除 |
| **find_package()** | 使用 HINTS | ✅ 使用 CMAKE_PREFIX_PATH | ✅ 使用 CMAKE_PREFIX_PATH |
| **构建工具查找** | CMAKE_PROGRAM_PATH | CMAKE_PROGRAM_PATH | CMake target |
| **符合最佳实践** | ❌ 否 | ⚠️ 部分 | ✅ 完全 |
| **风险** | N/A | 低 | 中 |

## 🎯 成功标准

### 步骤 1 成功标准
- ✅ CMake 配置阶段无错误
- ✅ find_package(gRPC) 成功
- ✅ find_package(protobuf) 成功
- ✅ RDC 能够找到 protoc 和 grpc_cpp_plugin
- ✅ RDC 构建成功

### 步骤 3 成功标准
- ✅ 所有步骤 1 的标准
- ✅ 不依赖任何硬编码路径
- ✅ 完全依赖 CMake 的标准机制

## 📝 后续改进（长期）

即使步骤 1 或步骤 3 成功，仍有以下改进点：

### 1. 修改 RDC 的 install 逻辑

**问题：** RDC 当前会安装整个 GRPC_ROOT
```cmake
# RDC 的 CMakeLists.txt (第321-353行)
install(
    DIRECTORY ${GRPC_ROOT}/
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/rdc/grpc
)
```

**改进：** RDC 不应该安装 gRPC，应该依赖已安装的 gRPC
- 需要修改 rocm-systems/projects/rdc/CMakeLists.txt
- 这需要 RDC 团队的配合

### 2. 改进 RDC 的工具查找方式

**问题：** 如果 RDC 使用 find_program()
```cmake
find_program(PROTOC_EXECUTABLE protoc)
```

**改进：** 使用 CMake target
```cmake
# 从 find_package(protobuf) 导入的
target_link_libraries(my_target protobuf::protoc)
# 或使用变量
set(PROTOC_EXECUTABLE $<TARGET_FILE:protobuf::protoc>)
```

### 3. 更新 TheRock 的依赖系统

**可选改进：** 让 THEROCK_BUNDLED_GRPC 不仅设置依赖，还提供路径变量
```cmake
# 当前：只是一个依赖名
RUNTIME_DEPS ${THEROCK_BUNDLED_GRPC}

# 改进：提供更多信息
set(THEROCK_GRPC_BIN_DIR ${gRPC_install_dir}/bin)
# 供需要的项目使用
```

## 总结

**当前状态：** 步骤 1 已实施 ✅

**下一步：** 测试步骤 1，根据结果决定是否进行步骤 3

**期望：** 至少步骤 1 应该成功，这已经解决了 code reviewer 最关心的硬编码 GRPC_ROOT 问题。

