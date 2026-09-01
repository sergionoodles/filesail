cmake_minimum_required(VERSION 3.24)

project(FileSail VERSION 0.1.0 LANGUAGES CXX)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "FileSail currently requires Linux filesystem primitives")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Concurrent)

add_executable(filesail-backend
    src/backend/main.cpp
    src/backend/backendserver.cpp
    src/backend/backendserver.h
    src/backend/fileoperations.cpp
    src/backend/fileoperations.h
)

target_link_libraries(filesail-backend PRIVATE Qt6::Core Qt6::Concurrent)
target_compile_options(filesail-backend PRIVATE
    $<$<CXX_COMPILER_ID:GNU,Clang>:-Wall -Wextra -Wpedantic>
)

include(GNUInstallDirs)
install(TARGETS filesail-backend RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

enable_testing()
add_test(
    NAME backend-protocol-smoke
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/backend-smoke.sh $<TARGET_FILE:filesail-backend>
)
