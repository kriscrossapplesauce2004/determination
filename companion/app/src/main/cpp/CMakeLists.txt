cmake_minimum_required(VERSION 3.22.1)
project(det_presenter LANGUAGES CXX)

add_library(det_presenter SHARED presenter.cpp)
target_include_directories(det_presenter PRIVATE ../../../../../graphics)
target_link_libraries(det_presenter PRIVATE android log)
