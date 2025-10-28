# Data Center Tools

if(THEROCK_ENABLE_RDC)
  # RDC (ROCm Data Center Tool) - GPU monitoring and administration
  # Uses statically-linked gRPC with hidden symbol visibility to prevent ODR violations.
  # Dependencies are discovered via CMAKE_PREFIX_PATH and find_package().

  # RDC requires gRPC build tools (protoc + grpc_cpp_plugin) at configure time.
  # Point GRPC_ROOT to the staged therock-grpc installation so the plugin finds
  # its dependent libraries (librocm_sysdeps_z, etc).
  #
  # TODO (RFC0007): Migrate RDC to use find_package(gRPC CONFIG) for modern CMake discovery.
  # Current approach uses -DGRPC_ROOT which is legacy but necessary until RDC's build system
  # is updated in the rocm-systems/projects/rdc repository. See RFC0007 lines 281-297.
  if(NOT TARGET ${THEROCK_BUNDLED_GRPC})
    message(FATAL_ERROR "Expected bundled gRPC target ${THEROCK_BUNDLED_GRPC} to exist")
  endif()
  get_target_property(_therock_grpc_stage ${THEROCK_BUNDLED_GRPC} THEROCK_STAGE_DIR)
  if(NOT _therock_grpc_stage)
    message(FATAL_ERROR "Failed to locate stage directory for ${THEROCK_BUNDLED_GRPC}")
  endif()
  set(_therock_grpc_root "${_therock_grpc_stage}/lib/rocm_sysdeps")

  therock_cmake_subproject_declare(rdc
    EXTERNAL_SOURCE_DIR "${THEROCK_ROCM_SYSTEMS_SOURCE_DIR}/projects/rdc"
    BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/rdc"
    BACKGROUND_BUILD

    CMAKE_ARGS
      -DBUILD_PROFILER=ON
      -DBUILD_STANDALONE=ON
      -DBUILD_RUNTIME=ON
      -DBUILD_RVS=OFF
      -DBUILD_TESTS=${THEROCK_BUILD_TESTING}
      -DHIP_PLATFORM=amd
      -DCMAKE_CXX_STANDARD=17
      -DGRPC_ROOT=${_therock_grpc_root}

    BUILD_DEPS
      amd-llvm

    RUNTIME_DEPS
      ROCR-Runtime
      amdsmi
      rocprofiler-sdk
      ${THEROCK_BUNDLED_LIBCAP}
      ${THEROCK_BUNDLED_ZLIB}
      ${THEROCK_BUNDLED_GRPC}

    INSTALL_DESTINATION
      portable-rdc

    INTERFACE_LINK_DIRS
      lib

    INTERFACE_INSTALL_RPATH_DIRS
      lib
  )

  therock_cmake_subproject_glob_c_sources(rdc
    SUBDIRS .
  )

  therock_cmake_subproject_provide_package(rdc rdc lib/cmake/rdc)

  therock_cmake_subproject_activate(rdc)

  # RDC validation tests (runtime tests excluded - require GPU hardware)

  therock_test_validate_shared_lib(
    PATH rdc/stage/portable-rdc/lib
    LIB_NAMES
      librdc_bootstrap.so
      librdc_client.so
  )

  # Verify gRPC symbols are hidden to prevent ODR violations
  add_test(
    NAME rdc-validate-no-grpc-symbol-pollution
    COMMAND bash -c "! nm -D ${CMAKE_CURRENT_BINARY_DIR}/rdc/stage/portable-rdc/lib/librdc_client.so* 2>/dev/null | grep -q ' T.*grpc::'"
  )
  set_tests_properties(rdc-validate-no-grpc-symbol-pollution PROPERTIES
    LABELS "rdc;symbol-visibility"
  )

  # Verify binaries exist
  add_test(
    NAME rdc-verify-binaries-exist
    COMMAND bash -c "test -x ${CMAKE_CURRENT_BINARY_DIR}/rdc/stage/portable-rdc/bin/rdcd && test -x ${CMAKE_CURRENT_BINARY_DIR}/rdc/stage/portable-rdc/bin/rdci"
  )
  set_tests_properties(rdc-verify-binaries-exist PROPERTIES
    LABELS "rdc;build-verification"
  )

  # Verify library SONAME structure
  add_test(
    NAME rdc-verify-library-sonames
    COMMAND bash -c "test -L ${CMAKE_CURRENT_BINARY_DIR}/rdc/stage/portable-rdc/lib/librdc.so && test -L ${CMAKE_CURRENT_BINARY_DIR}/rdc/stage/portable-rdc/lib/librdc_client.so && test -L ${CMAKE_CURRENT_BINARY_DIR}/rdc/stage/portable-rdc/lib/librdc_bootstrap.so"
  )
  set_tests_properties(rdc-verify-library-sonames PROPERTIES
    LABELS "rdc;build-verification"
  )

  # Provide RDC artifact (portable-rdc/ structure per RFC0007)
  therock_provide_artifact(rdc
    TARGET_NEUTRAL
    DESCRIPTOR artifact-rdc.toml
    COMPONENTS
      dbg
      dev
      doc
      lib
      run
    SUBPROJECT_DEPS
      amdsmi
      rocprofiler-sdk
      rdc
  )

endif(THEROCK_ENABLE_RDC)
