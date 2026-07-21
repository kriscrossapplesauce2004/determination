cmake_minimum_required(VERSION 3.22.1)
project(det_presenter LANGUAGES CXX)

add_library(det_presenter SHARED presenter.cpp)
target_include_directories(det_presenter PRIVATE ../../../../../graphics)
target_link_libraries(det_presenter PRIVATE android log)

# Android 15+ devices may use 16 KiB pages. NDK r27 otherwise emits 4 KiB
# PT_LOAD alignment, which Android 16 reports at launch and cannot mmap safely
# on a 16 KiB kernel.
target_link_options(det_presenter PRIVATE "-Wl,-z,max-page-size=16384")
