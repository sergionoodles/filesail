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

configure_file(
    src/backend/filesail_version.h.in
    ${CMAKE_CURRENT_BINARY_DIR}/generated/filesail_version.h
    @ONLY
)

add_executable(filesail-backend
    src/backend/main.cpp
    src/backend/backendserver.cpp
    src/backend/backendserver.h
    src/backend/fileoperations.cpp
    src/backend/fileoperations.h
)

target_link_libraries(filesail-backend PRIVATE Qt6::Core Qt6::Concurrent)
target_include_directories(filesail-backend PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/generated)
target_compile_options(filesail-backend PRIVATE
    $<$<CXX_COMPILER_ID:GNU,Clang>:-Wall -Wextra -Wpedantic>
)

include(GNUInstallDirs)
set(FILESAIL_INSTALL_DATA_DIR "${CMAKE_INSTALL_DATADIR}/filesail")

configure_file(
    packaging/filesail.in
    ${CMAKE_CURRENT_BINARY_DIR}/filesail
    @ONLY
)
configure_file(
    manifest.json.in
    ${CMAKE_CURRENT_BINARY_DIR}/manifest.json
    @ONLY
)

install(TARGETS filesail-backend RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(PROGRAMS ${CMAKE_CURRENT_BINARY_DIR}/filesail DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES shell.qml ${CMAKE_CURRENT_BINARY_DIR}/manifest.json
    DESTINATION ${FILESAIL_INSTALL_DATA_DIR})
install(DIRECTORY qml integrations DESTINATION ${FILESAIL_INSTALL_DATA_DIR}
    PATTERN "*.qml" PATTERN "qmldir" PATTERN "*.json")
install(FILES packaging/dev.filesail.FileSail.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)

enable_testing()
add_test(
    NAME backend-protocol-smoke
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/backend-smoke.sh $<TARGET_FILE:filesail-backend>
)
add_test(
    NAME manifest-version-consistency
    COMMAND ${CMAKE_COMMAND}
        -DPROJECT_VERSION=${PROJECT_VERSION}
        -DMANIFEST=${CMAKE_CURRENT_SOURCE_DIR}/manifest.json
        -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check-manifest-version.cmake
)
