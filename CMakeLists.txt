cmake_minimum_required(VERSION 3.24)

set(FILESAIL_VERSION "0.1.0" CACHE STRING "FileSail project version")
project(FileSail VERSION ${FILESAIL_VERSION} LANGUAGES CXX)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "FileSail currently requires Linux filesystem primitives")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Concurrent DBus)
find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBARCHIVE REQUIRED IMPORTED_TARGET libarchive)

configure_file(
    src/backend/filesail_version.h.in
    ${CMAKE_CURRENT_BINARY_DIR}/generated/filesail_version.h
    @ONLY
)

add_executable(filesail-backend
    src/backend/main.cpp
    src/backend/logging.cpp
    src/backend/logging.h
    src/backend/backendserver.cpp
    src/backend/backendserver.h
    src/backend/cancellation.h
    src/backend/fileoperations.cpp
    src/backend/fileoperations.h
    src/backend/foldercontext.cpp
    src/backend/foldercontext.h
    src/backend/savedlocations.cpp
    src/backend/savedlocations.h
    src/backend/previewservice.cpp
    src/backend/previewservice.h
)

target_link_libraries(filesail-backend PRIVATE Qt6::Core Qt6::Concurrent Qt6::DBus PkgConfig::LIBARCHIVE)
target_include_directories(filesail-backend PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/generated)
target_compile_options(filesail-backend PRIVATE
    $<$<CXX_COMPILER_ID:GNU,Clang>:-Wall -Wextra -Wpedantic>
)

include(GNUInstallDirs)
set(FILESAIL_INSTALL_DATA_DIR "${CMAKE_INSTALL_DATADIR}/filesail")

# `packaging/filesail.in` is a shell script. Quote configured paths as shell
# literals instead of inserting trusted-build configuration as executable text.
function(filesail_shell_quote value output)
    string(REPLACE "'" "'\"'\"'" quoted "${value}")
    set(${output} "'${quoted}'" PARENT_SCOPE)
endfunction()

filesail_shell_quote("${CMAKE_INSTALL_FULL_DATADIR}" FILESAIL_INSTALL_DATADIR_SHELL)
filesail_shell_quote("${CMAKE_INSTALL_FULL_BINDIR}" FILESAIL_INSTALL_BINDIR_SHELL)

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
install(FILES shell.qml logo.png ${CMAKE_CURRENT_BINARY_DIR}/manifest.json
    DESTINATION ${FILESAIL_INSTALL_DATA_DIR})
install(DIRECTORY qml integrations DESTINATION ${FILESAIL_INSTALL_DATA_DIR}
    FILES_MATCHING
    PATTERN "*.qml" PATTERN "qmldir" PATTERN "*.json" PATTERN "*.ttf" PATTERN "LUCIDE-LICENSE")
install(FILES packaging/dev.filesail.FileSail.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
install(FILES logo.png
    DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/1200x1200/apps
    RENAME filesail.png)
install(FILES logo.png
    DESTINATION ${CMAKE_INSTALL_DATADIR}/pixmaps
    RENAME filesail.png)

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
