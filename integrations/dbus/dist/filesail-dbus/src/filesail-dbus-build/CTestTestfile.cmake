# CMake generated Testfile for 
# Source directory: /home/sergio/workspace/filesail/integrations/dbus/dist/filesail-dbus/src/filesail
# Build directory: /home/sergio/workspace/filesail/integrations/dbus/dist/filesail-dbus/src/filesail-dbus-build
# 
# This file includes the relevant testing commands required for 
# testing this directory and lists subdirectories to be tested as well.
add_test("backend-protocol-smoke" "/home/sergio/workspace/filesail/integrations/dbus/dist/filesail-dbus/src/filesail/tests/backend-smoke.sh" "/home/sergio/workspace/filesail/integrations/dbus/dist/filesail-dbus/src/filesail-dbus-build/filesail-backend")
set_tests_properties("backend-protocol-smoke" PROPERTIES  _BACKTRACE_TRIPLES "/home/sergio/workspace/filesail/integrations/dbus/dist/filesail-dbus/src/filesail/CMakeLists.txt;93;add_test;/home/sergio/workspace/filesail/integrations/dbus/dist/filesail-dbus/src/filesail/CMakeLists.txt;0;")
add_test("manifest-version-consistency" "/usr/bin/cmake" "-DVERSION_FILE=/home/sergio/workspace/filesail/integrations/dbus/dist/filesail-dbus/src/filesail/VERSION" "-DPROJECT_VERSION=2026.9.1" "-DMANIFEST=/home/sergio/workspace/filesail/integrations/dbus/dist/filesail-dbus/src/filesail-dbus-build/manifest.json" "-P" "/home/sergio/workspace/filesail/integrations/dbus/dist/filesail-dbus/src/filesail/tests/check-manifest-version.cmake")
set_tests_properties("manifest-version-consistency" PROPERTIES  _BACKTRACE_TRIPLES "/home/sergio/workspace/filesail/integrations/dbus/dist/filesail-dbus/src/filesail/CMakeLists.txt;97;add_test;/home/sergio/workspace/filesail/integrations/dbus/dist/filesail-dbus/src/filesail/CMakeLists.txt;0;")
