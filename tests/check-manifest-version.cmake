if(NOT DEFINED VERSION_FILE OR NOT DEFINED PROJECT_VERSION OR NOT DEFINED PLUGIN_MANIFEST)
    message(FATAL_ERROR "VERSION_FILE, PROJECT_VERSION, and PLUGIN_MANIFEST are required")
endif()

file(READ "${VERSION_FILE}" version_contents)
string(STRIP "${version_contents}" version)
if(NOT version STREQUAL PROJECT_VERSION)
    message(FATAL_ERROR
        "VERSION (${version}) does not match PROJECT_VERSION (${PROJECT_VERSION})")
endif()

file(READ "${PLUGIN_MANIFEST}" manifest_contents)
string(REGEX MATCH "(^|\n)version[ \t]*=[ \t]*\"([^\"]+)\"" manifest_match "${manifest_contents}")
if(NOT manifest_match)
    message(FATAL_ERROR "No version found in Noctalia plugin manifest")
endif()
set(manifest_version "${CMAKE_MATCH_2}")

if(NOT manifest_version STREQUAL PROJECT_VERSION)
    message(FATAL_ERROR
        "Noctalia plugin version (${manifest_version}) does not match PROJECT_VERSION (${PROJECT_VERSION})")
endif()
