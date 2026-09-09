cmake_minimum_required(VERSION 3.24)

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" FILESAIL_VERSION)
string(STRIP "${FILESAIL_VERSION}" FILESAIL_VERSION)
if(NOT FILESAIL_VERSION MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+$")
    message(FATAL_ERROR "VERSION must contain a numeric major.minor.patch version")
endif()
project(FileSail VERSION ${FILESAIL_VERSION} LANGUAGES CXX)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "FileSail currently requires Linux filesystem primitives")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_AUTOMOC ON)

option(FILESAIL_BUILD_DBUS "Build the optional FileManager1 D-Bus service" OFF)

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

if(FILESAIL_BUILD_DBUS)
    add_executable(filesail-filemanager1
        src/filemanager1/main.cpp
        src/filemanager1/filemanager1service.cpp
        src/filemanager1/filemanager1service.h
        src/filemanager1/uriresolver.cpp
        src/filemanager1/uriresolver.h
    )
    target_link_libraries(filesail-filemanager1 PRIVATE Qt6::Core Qt6::DBus)
    target_compile_options(filesail-filemanager1 PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang>:-Wall -Wextra -Wpedantic>
    )
endif()

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
if(FILESAIL_BUILD_DBUS)
    install(TARGETS filesail-filemanager1 RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
    install(FILES packaging/filesail-filemanager1.service
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/systemd/user)
endif()
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
if(FILESAIL_BUILD_DBUS)
    add_test(
        NAME filemanager1-smoke
        COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/filemanager1-smoke.sh
            $<TARGET_FILE:filesail-filemanager1>
    )
endif()
add_test(
    NAME backend-protocol-smoke
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/backend-smoke.sh $<TARGET_FILE:filesail-backend>
)
add_test(
    NAME manifest-version-consistency
    COMMAND ${CMAKE_COMMAND}
        -DVERSION_FILE=${CMAKE_CURRENT_SOURCE_DIR}/VERSION
        -DPROJECT_VERSION=${PROJECT_VERSION}
        -DMANIFEST=${CMAKE_CURRENT_BINARY_DIR}/manifest.json
        -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check-manifest-version.cmake
)
