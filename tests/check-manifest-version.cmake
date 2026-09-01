if(NOT DEFINED PROJECT_VERSION OR NOT DEFINED MANIFEST)
    message(FATAL_ERROR "PROJECT_VERSION and MANIFEST are required")
endif()

file(READ "${MANIFEST}" manifest_contents)
string(JSON manifest_version GET "${manifest_contents}" version)

if(NOT manifest_version STREQUAL PROJECT_VERSION)
    message(FATAL_ERROR
        "manifest.json version (${manifest_version}) does not match PROJECT_VERSION (${PROJECT_VERSION})")
endif()
