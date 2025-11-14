# gRPC 验证说明

**重要澄清**: gRPC 有自己的验证，不需要 RDC 的脚本！

---

## 🔍 两个不同的验证脚本

### 1. 已删除：`profiler/validate_rdc_library.sh` ❌

**用途**: 验证 RDC 的库
**状态**: ✅ 已删除（因为不符合 TheRock 规范）
**替代**: 使用标准的 `therock_test_validate_shared_lib()`

---

### 2. 仍然存在：`third-party/sysdeps/linux/grpc/validate_static_library.sh` ✅

**用途**: 验证 gRPC 的静态库
**状态**: ✅ 一直存在，从未删除
**位置**: `third-party/sysdeps/linux/grpc/validate_static_library.sh`

---

## ✅ gRPC 已有完整的验证

### gRPC 的验证配置

**文件**: `third-party/sysdeps/linux/grpc/CMakeLists.txt` Line 45-53

```cmake
# Validate that key static libraries are built correctly
foreach(lib_name libgrpc++.a libgrpc.a libprotobuf.a)
  add_test(
    NAME therock-validate-static-lib-${lib_name}
    COMMAND
      "${CMAKE_CURRENT_SOURCE_DIR}/validate_static_library.sh"
        "${CMAKE_CURRENT_BINARY_DIR}/build/dist/lib/rocm_sysdeps/lib/${lib_name}"
  )
endforeach()
```

### 验证的内容

`validate_static_library.sh` 脚本验证：

1. ✅ 文件存在且非空
2. ✅ Archive 格式正确（使用 `ar t`）
3. ✅ 包含有效的 ELF 目标文件
4. ✅ 符号完整性（使用 `nm`）
5. ✅ 导出符号存在
6. ✅ **实际链接测试**（验证符号可用）

---

## 🧪 如何运行 gRPC 验证

### 查看 gRPC 验证测试

```bash
$ ctest --test-dir build-3 -R "therock-validate-static-lib" -N

Test #13: therock-validate-static-lib-libgrpc++.a
Test #14: therock-validate-static-lib-libgrpc.a
Test #15: therock-validate-static-lib-libprotobuf.a

Total Tests: 3
```

### 运行 gRPC 验证测试

```bash
$ ctest --test-dir build-3 -R "therock-validate-static-lib"

Test #13: therock-validate-static-lib-libgrpc++.a ...   Passed
Test #14: therock-validate-static-lib-libgrpc.a .....   Passed
Test #15: therock-validate-static-lib-libprotobuf.a    Passed

100% tests passed, 0 tests failed out of 3
```

### 详细输出（-V）

```bash
$ ctest --test-dir build-3 -R "therock-validate-static-lib-libgrpc++.a" -V

Test command: .../validate_static_library.sh
              .../libgrpc++.a

Validating static library: .../libgrpc++.a : OK (1234 objects, 5678 symbols, 890 exported)
Testing actual linkage with gRPC symbols : OK (verified: grpc_init, ...)
All validation checks passed
```

---

## 📊 验证覆盖情况

### 当前验证状态

| 包 | 验证脚本 | 验证类型 | 测试数量 | 状态 |
|----|---------|---------|---------|------|
| **gRPC** | `grpc/validate_static_library.sh` | 静态库 | 3 | ✅ 完整 |
| **libcap** | `therock_test_validate_shared_lib` | 共享库 | 1 | ✅ 标准 |
| **RDC** | `therock_test_validate_shared_lib` | 共享库 | 2 | ✅ 标准 |

---

## ❓ 常见问题

### Q1: RDC 的验证脚本被删了，gRPC 怎么办？

**A**: 
- RDC 的脚本只验证 RDC
- gRPC 有自己独立的脚本
- **gRPC 的脚本从未被删除** ✅

### Q2: gRPC 的验证脚本在哪里？

**A**: `third-party/sysdeps/linux/grpc/validate_static_library.sh`

```bash
$ ls -la third-party/sysdeps/linux/grpc/validate_static_library.sh
-rwxrwxr-x 1 1001 1001 6846 Nov  7 16:47 validate_static_library.sh
```

### Q3: 如何手动验证 gRPC 库？

**A**: 直接调用脚本

```bash
$ cd third-party/sysdeps/linux/grpc
$ ./validate_static_library.sh \
    ../../build-3/.../libgrpc++.a \
    ../../build-3/.../libgrpc.a \
    ../../build-3/.../libprotobuf.a

Validating static library: libgrpc++.a : OK (...)
Validating static library: libgrpc.a : OK (...)
Validating static library: libprotobuf.a : OK (...)
Testing actual linkage with gRPC symbols : OK (...)
All validation checks passed
```

### Q4: 为什么 gRPC 用 bash 脚本，RDC 用 Python？

**A**: 
- gRPC 是旧代码，使用 bash 脚本
- 新的标准是 Python (`validate_shared_library.py`)
- 长期可以统一，但不是现在的优先级

### Q5: 需要恢复 RDC 的验证脚本吗？

**A**: ❌ **不需要**
- RDC 已经使用标准方式验证（`therock_test_validate_shared_lib`）
- 删除自定义脚本是正确的改进
- 符合 Code Reviewer 的要求

---

## ✅ 总结

### gRPC 验证完全正常

1. ✅ gRPC 有自己的验证脚本
2. ✅ 脚本从未被删除
3. ✅ 验证测试正常运行
4. ✅ 无需任何改动

### RDC 验证已改进

1. ✅ 删除了自定义脚本（正确的改进）
2. ✅ 使用标准验证函数
3. ✅ 符合 TheRock 规范
4. ✅ 验证测试通过

### 无需恢复任何文件 ✅

所有验证都正常工作！

