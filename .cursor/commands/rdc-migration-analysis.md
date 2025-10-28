# RDC 构建配置迁移分析

## 当前状态

### 当前目录结构
```
TheRock/
├── systems-tools/              # 新增的顶级目录（问题所在）
│   ├── CMakeLists.txt         # RDC 构建配置
│   ├── artifact-rdc.toml      # RDC artifact 描述
│   └── validate_rdc_library.sh # RDC 测试脚本
├── rocm-systems/
│   └── projects/
│       └── rdc/               # RDC 源代码已经在这里
└── CMakeLists.txt
    └── add_subdirectory(systems-tools)  # 第483行
```

### 当前构建流程
1. TheRock 主 CMakeLists.txt 通过 `add_subdirectory(systems-tools)` 加载
2. `systems-tools/CMakeLists.txt` 使用 `therock_cmake_subproject_declare()` 声明 RDC
3. 源代码通过 `EXTERNAL_SOURCE_DIR` 指向 `rocm-systems/projects/rdc`
4. Artifact 通过独立的 `artifact-rdc.toml` 定义

## RFC0003 规范要求

### 核心原则
1. **不添加新的顶级目录**：应整合到 `rocm-systems/` 或 `rocm-libraries/`
2. **层次化组织**：按功能语义组织目录结构
3. **构建文件迁移**：将 TheRock 的构建配置迁移到子模块仓库中

### RFC 建议的 rocm-systems 结构
```
rocm-systems/
  base/                    # 基础组件（rocm-core, rocm-smi-lib, rocprofiler-register）
    therock.cmake
    therock_subprojects.cmake
    therock_artifact_base.toml
  runtime/                 # 运行时组件（ROCR, HIP, CLR）
    therock.cmake
    therock_subprojects.cmake
    therock_artifact_*.toml
  profiler/                # 性能分析工具
    therock.cmake
    therock_subprojects.cmake
    therock_artifact_rocprofiler-sdk.toml
```

## 问题分析

### 1. RDC 的语义分类
根据 RDC (ROCm Data Center Tool) 的功能定位：
- **功能**：数据中心管理和监控工具
- **依赖**：ROCR-Runtime, amdsmi, rocprofiler-sdk
- **类别**：系统管理工具

**结论**：RDC 应该归类为"base"或"runtime"层面的系统工具，而不是独立的顶级目录。

### 2. 与 amdsmi 的对比
```
# amdsmi 的构建位置（参考案例）
TheRock/base/
  ├── amdsmi/             # amdsmi 源码子模块
  ├── CMakeLists.txt      # 包含 amdsmi 的构建配置
  └── artifact.toml       # 统一的 base artifact 描述

# RDC 的依赖关系
RDC -> amdsmi (依赖 amdsmi)
```

由于 RDC 依赖 amdsmi，且都是系统管理工具，应该放在相同层级或更上层。

### 3. 当前实现的问题
1. **违反 RFC0003**：添加了新的顶级目录 `systems-tools/`
2. **架构不一致**：其他系统工具在 `base/` 中，RDC 却独立
3. **未来重构负担**：需要再次迁移以符合 RFC
4. **技术债务**：增加了维护成本

## 迁移方案

### 方案 A：整合到 base/ 目录（推荐）

#### 理由
1. ✅ 与 amdsmi、rocm_smi_lib 等系统工具在同一层级
2. ✅ 符合 RDC 作为基础系统工具的定位
3. ✅ 依赖关系清晰（base 组件可以依赖其他 base 组件）
4. ✅ 最小化改动，容易实施

#### 目标目录结构
```
TheRock/
├── base/
│   ├── CMakeLists.txt          # 添加 RDC 构建配置
│   ├── artifact.toml           # 添加 RDC artifact 描述
│   └── validate_rdc_library.sh # 移动测试脚本到这里
├── rocm-systems/
│   └── projects/
│       └── rdc/                # 源代码保持不变
└── CMakeLists.txt
    └── add_subdirectory(base)  # 已存在，无需改动
```

#### 需要改动的文件

##### 1. `/workspace/TheRock/base/CMakeLists.txt`
**位置**：文件末尾，在 `therock_provide_artifact(base ...)` 之前

**添加内容**：
```cmake
################################################################################
# RDC (ROCm Data Center Tool)
################################################################################

if(THEROCK_ENABLE_RDC)
    # Point GRPC_ROOT to the actual gRPC build location
    set(_grpc_build_path "${THEROCK_BINARY_DIR}/third-party/sysdeps/linux/grpc/build/stage/lib/rocm_sysdeps")

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
            "-DGRPC_ROOT=${_grpc_build_path}"
            -DGRPC_DESIRED_VERSION=1.76.0
            "-DCMAKE_PROGRAM_PATH=${_grpc_build_path}/bin"

        BUILD_DEPS
            amd-llvm

        RUNTIME_DEPS
            ROCR-Runtime
            amdsmi
            rocprofiler-sdk
            ${THEROCK_BUNDLED_LIBCAP}
            ${THEROCK_BUNDLED_ZLIB}
            ${THEROCK_BUNDLED_GRPC}

        INTERFACE_LINK_DIRS
            lib
    )

    therock_cmake_subproject_glob_c_sources(rdc
        SUBDIRS .
    )

    therock_cmake_subproject_provide_package(rdc rdc lib/cmake/rdc)

    therock_cmake_subproject_activate(rdc)

    # RDC: use custom bash script to validate shared libraries
    foreach(lib_name librdc_rocr.so librdc_rocp.so)
        add_test(
            NAME therock-validate-shared-lib-${lib_name}
            COMMAND
                "${CMAKE_CURRENT_SOURCE_DIR}/validate_rdc_library.sh"
                    "${CMAKE_CURRENT_BINARY_DIR}/rdc/dist/lib/rdc/${lib_name}"
        )
    endforeach()

endif()
```

**注意**：测试脚本路径从 `systems-tools/validate_rdc_library.sh` 改为 `base/validate_rdc_library.sh`，构建路径从 `systems-tools/dist` 改为 `base/rdc/dist`。

##### 2. `/workspace/TheRock/base/artifact.toml`
**位置**：文件末尾添加

**添加内容**：
```toml
# rdc
[components.dbg."base/rdc/stage"]
[components.dev."base/rdc/stage"]
include = [
  "include/**",
  "lib/cmake/**",
  "lib/rdc/grpc/**", 
]
[components.doc."base/rdc/stage"]
include = [
  "share/doc/rdc/**",
]
[components.lib."base/rdc/stage"]
include = [
  "lib/*.so*",
  "lib/rdc/*.so*",
]
[components.run."base/rdc/stage"]
include = [
  "lib/*.so*",
  "lib/rdc/*.so*",
  "libexec/rdc/**",
  "share/rdc/**",
]
```

**注意**：路径从 `systems-tools/stage` 改为 `base/rdc/stage`。

##### 3. `/workspace/TheRock/base/CMakeLists.txt` - 更新 artifact
**修改位置**：`therock_provide_artifact(base ...)` 调用

**修改内容**：在 `SUBPROJECT_DEPS` 列表中添加 `rdc`（如果启用）

示例：
```cmake
therock_provide_artifact(base
  TARGET_NEUTRAL
  DESCRIPTOR artifact.toml
  COMPONENTS
    dbg
    dev
    doc
    lib
    run
    test
  SUBPROJECT_DEPS
    rocm-cmake
    rocm-core
    amdsmi
    rocm_smi_lib
    rocprofiler-register
    $<$<BOOL:${THEROCK_ENABLE_RDC}>:rdc>  # 条件性添加
)
```

##### 4. `/workspace/TheRock/CMakeLists.txt`
**删除**：第483行
```cmake
add_subdirectory(systems-tools)  # 删除这一行
```

##### 5. 文件移动
```bash
# 移动测试脚本
mv systems-tools/validate_rdc_library.sh base/

# 删除 systems-tools 目录
rm -rf systems-tools/
```

### 方案 B：创建 rocm-systems/tools/ 子目录（符合 RFC 长期规划）

这是更符合 RFC0003 长期愿景的方案，但需要在 `rocm-systems` 子模块中进行改动。

#### 目标结构（未来状态）
```
rocm-systems/
  tools/                         # 新增：系统工具层
    therock.cmake
    therock_subprojects.cmake
    therock_artifact_tools.toml
    rdc/                         # 从 projects/ 移动到这里
      [RDC 源代码]
```

#### 困难点
1. 需要修改 `rocm-systems` 子模块（不在当前仓库）
2. RFC0003 仍处于 draft 状态，目录结构未最终确定
3. 需要协调多个团队和仓库的修改

#### 建议
暂不采用此方案，等待 RFC0003 正式通过后，统一进行目录重组。

## 推荐实施方案

### 短期方案（立即实施）
**采用方案 A**：将 RDC 构建配置整合到 `base/` 目录

**原因**：
1. ✅ 符合当前 TheRock 的目录组织模式
2. ✅ 最小化改动，风险最低
3. ✅ 消除新的顶级目录，部分满足 RFC0003 要求
4. ✅ 与依赖项（amdsmi）在同一层级，逻辑清晰

**不符合之处**：
- ⚠️ 仍然是 TheRock 主导构建配置，而非在 rocm-systems 中
- ⚠️ 未采用 `therock.cmake` 等新的构建文件命名

### 长期方案（RFC0003 正式后）
1. 等待 RFC0003 正式通过
2. 观察 rocm-systems 的目录重组
3. 在统一的重构中，将 RDC 构建配置迁移到 `rocm-systems/` 内部
4. 采用 RFC 建议的 `therock_subprojects.cmake` 等新机制

## 改动影响评估

### 文件变更统计（方案 A）
```
新增：1 个文件
  - base/validate_rdc_library.sh

修改：3 个文件
  - base/CMakeLists.txt          (+60 行)
  - base/artifact.toml           (+20 行)
  - CMakeLists.txt               (-1 行)

删除：整个目录
  - systems-tools/               (-3 个文件)
```

### 构建行为变化
- **无变化**：RDC 的构建逻辑完全相同
- **路径变化**：
  - 构建目录：`build/systems-tools/rdc/` → `build/base/rdc/`
  - Stage 目录：`systems-tools/stage/` → `base/rdc/stage/`
  - Artifact 路径：独立 `rdc` artifact → 合并到 `base` artifact

### 下游影响
- **包装脚本**：可能需要更新 artifact 路径引用
- **CI/CD**：如果有针对 `systems-tools` 的特殊处理，需要更新
- **文档**：需要更新构建文档

### 依赖关系变化
**之前**：
```
CMakeLists.txt
  └── systems-tools/CMakeLists.txt
        └── rdc (subproject)
```

**之后**：
```
CMakeLists.txt
  └── base/CMakeLists.txt
        ├── amdsmi (subproject)
        └── rdc (subproject)  # RDC 可以直接依赖 amdsmi
```

这样更符合依赖关系的层次结构。

## 潜在风险

### 风险 1：Artifact 合并
**问题**：RDC 从独立 artifact 变为 base artifact 的一部分

**影响**：
- 用户如果只想安装 RDC，现在需要安装整个 base 包
- 包大小可能增加

**缓解措施**：
- base artifact 本身就包含多个小组件，这是正常的
- 可以在 artifact.toml 中使用 `optional` 标记
- 未来 RFC 实施时可以重新拆分

### 风险 2：测试路径变化
**问题**：测试脚本引用的路径需要更新

**影响**：CI/CD 测试可能失败

**缓解措施**：
- 已在方案中明确标注路径变化
- 测试时仔细验证

### 风险 3：与 RFC0003 的对齐
**问题**：方案 A 是过渡方案，未来仍需重构

**影响**：需要二次迁移

**缓解措施**：
- 当前改动较小，未来重构成本不高
- 可以等 RFC 稳定后统一处理
- 总比保留 `systems-tools/` 顶级目录更接近 RFC 目标

## 实施步骤

### 阶段 1：代码修改
1. 复制 `systems-tools/CMakeLists.txt` 中的 RDC 配置到 `base/CMakeLists.txt`
2. 更新路径引用（特别是测试脚本路径）
3. 将 `artifact-rdc.toml` 的内容合并到 `base/artifact.toml`
4. 更新路径前缀（`systems-tools/stage` → `base/rdc/stage`）
5. 移动 `validate_rdc_library.sh` 到 `base/`
6. 删除 `CMakeLists.txt` 中的 `add_subdirectory(systems-tools)`

### 阶段 2：验证
1. 清理构建目录：`rm -rf build/`
2. 重新配置：`cmake -B build -DTHEROCK_ENABLE_RDC=ON`
3. 构建：`cmake --build build`
4. 运行测试：`ctest --test-dir build -R rdc`

### 阶段 3：清理
1. 删除 `systems-tools/` 目录
2. 更新相关文档

### 阶段 4：后续跟进
1. 监控 RFC0003 的进展
2. 参与讨论，确保 RDC 在未来规划中有明确位置
3. 在 RFC 正式后，规划下一次迁移

## 总结

**推荐采用方案 A**，将 RDC 整合到 `base/` 目录，原因：

1. ✅ **符合当前架构**：与 amdsmi 等系统工具一致
2. ✅ **消除违规**：移除新增的顶级目录
3. ✅ **改动最小**：风险可控，易于实施
4. ✅ **依赖合理**：RDC 与其依赖项在同一层级
5. ✅ **可逆性好**：未来 RFC 实施时，容易再次迁移

**不推荐保留 `systems-tools/`**，因为：
1. ❌ 违反 RFC0003 的核心原则
2. ❌ 增加技术债务
3. ❌ 架构不一致
4. ❌ 未来必然需要重构

**关于 Code Reviewer 的关切**：
> "I am not sure we want to add another top level directory as this also will need to be reworked with regards to RFC0003-Build-Tree-Normalization.md"

**回应**：
- 关切**完全合理且必要**
- RFC0003 明确反对添加新的顶级目录
- 应该在 PR 阶段就采用正确的结构
- 避免"先错误实现，再重构"的技术债务累积

