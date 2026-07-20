cmake_minimum_required(VERSION 3.22)
project(determination_control LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(detcontrol STATIC
    src/adapter.cpp
    src/protocol.cpp
    src/state.cpp
    src/system.cpp
    src/transition.cpp
)
target_include_directories(detcontrol PUBLIC include)
target_compile_options(detcontrol PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(detd src/detd.cpp)
target_link_libraries(detd PRIVATE detcontrol)
target_compile_options(detd PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(detctl src/detctl.cpp)
target_link_libraries(detctl PRIVATE detcontrol)
target_compile_options(detctl PRIVATE -Wall -Wextra -Wpedantic -Werror)

if(ANDROID)
    target_link_libraries(detcontrol PUBLIC log)
    target_link_options(detd PRIVATE -static-libstdc++)
    target_link_options(detctl PRIVATE -static-libstdc++)
else()
    enable_testing()

    add_executable(det-control-tests
        tests/control_tests.cpp
    )
    target_link_libraries(det-control-tests PRIVATE detcontrol)
    target_compile_options(det-control-tests PRIVATE
        -Wall -Wextra -Wpedantic -Werror
    )
    add_test(NAME det-control-tests COMMAND det-control-tests)
endif()
