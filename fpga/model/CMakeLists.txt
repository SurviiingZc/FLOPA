cmake_minimum_required(VERSION 3.16)

project(dit_fa_model_bench LANGUAGES C CXX)

option(DIT_FA_ENABLE_PL "Build the VCK190 XRT attention callback" OFF)

set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)

set(LLAMA_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/llama.cpp")
if(NOT EXISTS "${LLAMA_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "Run scripts/fetch_llama_cpp.sh before configuring")
endif()

add_subdirectory("${LLAMA_CPP_DIR}" llama.cpp EXCLUDE_FROM_ALL)

add_executable(dit_fa_model_bench host/dit_fa_model_bench.cpp)
target_compile_features(dit_fa_model_bench PRIVATE cxx_std_17)
target_compile_options(dit_fa_model_bench PRIVATE -Wall -Wextra -Werror)
target_link_libraries(dit_fa_model_bench PRIVATE llama)

if(DIT_FA_ENABLE_PL)
    find_library(XRT_COREUTIL_LIBRARY xrt_coreutil REQUIRED)
    find_library(UUID_LIBRARY uuid REQUIRED)
    target_sources(dit_fa_model_bench PRIVATE host/pl_attention.cpp)
    target_compile_definitions(dit_fa_model_bench PRIVATE DIT_FA_ENABLE_PL=1)
    target_include_directories(
        dit_fa_model_bench
        PRIVATE
            "${CMAKE_SYSROOT}/usr/include/xrt"
    )
    target_link_libraries(
        dit_fa_model_bench
        PRIVATE
            "${XRT_COREUTIL_LIBRARY}"
            "${UUID_LIBRARY}"
            pthread
            rt
            dl
    )
endif()
