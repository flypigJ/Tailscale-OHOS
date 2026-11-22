cmake_minimum_required(VERSION 3.13)
project(tailscale_ohos)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})
include_directories(${NATIVERENDER_ROOT_PATH}/../../../../native/go_bridge/dist/arm64-v8a)

add_library(tailscale_go SHARED IMPORTED)
set_target_properties(tailscale_go PROPERTIES
    IMPORTED_LOCATION ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libtailscale_go.so)

add_library(tailscale_ohos SHARED napi_init.cpp)

target_compile_options(tailscale_ohos PRIVATE
    -fstack-protector-strong
    -fvisibility=hidden
    $<$<NOT:$<CONFIG:Debug>>:-O2>
    $<$<NOT:$<CONFIG:Debug>>:-D_FORTIFY_SOURCE=2>
)

target_link_options(tailscale_ohos PRIVATE
    -Wl,-z,relro,-z,now,-z,noexecstack
)

target_link_libraries(tailscale_ohos PUBLIC tailscale_go libace_napi.z.so libhilog_ndk.z.so)
