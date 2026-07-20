cmake_minimum_required(VERSION 3.20)
project(determination_audio LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_executable(det-audio-probe src/det_audio_probe.cpp)
target_compile_options(det-audio-probe PRIVATE
    -Wall -Wextra -Wpedantic -Werror
    -ffunction-sections -fdata-sections)
target_link_options(det-audio-probe PRIVATE -Wl,--gc-sections)

install(TARGETS det-audio-probe RUNTIME DESTINATION bin)

include(CTest)
if(BUILD_TESTING AND NOT CMAKE_CROSSCOMPILING)
    add_test(NAME audio-probe-help COMMAND det-audio-probe --help)
    add_test(NAME audio-probe-fixture
        COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/fixture-test.sh
                $<TARGET_FILE:det-audio-probe>)
endif()
