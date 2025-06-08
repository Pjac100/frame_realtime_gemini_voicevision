# Sets the minimum CMake version required.
cmake_minimum_required(VERSION 3.10)

# Project name (can be anything, not directly used by Flutter FFI loading usually)
project(sqlite_native_lib C)

# --- Configuration for SQLite and sqlite-vec ---

# Define the path to your native C source files, relative to this CMakeLists.txt file.
# This path goes up two levels from 'android/app/' to the project root, then into 'native_src'.
set(SQLITE_SOURCES_DIR ../../native_src)

# Add the directory containing your C headers (sqlite3.h, sqlite-vec.h) to the include path.
# This allows #include "sqlite3.h" and #include "sqlite-vec.h" in your C files to work.
include_directories(${SQLITE_SOURCES_DIR})

# --- Define the native library ---

# This will be the name of the compiled library (e.g., libsqlite_vector_search.so on Android)
set(LIBRARY_NAME sqlite_vector_search)

# Add your C source files to be compiled into the library.
add_library(${LIBRARY_NAME} SHARED
        ${SQLITE_SOURCES_DIR}/sqlite3.c
        ${SQLITE_SOURCES_DIR}/sqlite-vec.c
)

# Build sqlite-vec directly into SQLite and enable extension support
target_compile_definitions(
    ${LIBRARY_NAME}
    PRIVATE
    SQLITE_CORE
    SQLITE_OMIT_LOAD_EXTENSION=0
)

# --- Compile Definitions for SQLite (Optional but often needed) ---
# Refer to SQLite and sqlite-vec documentation if you encounter issues or need
# specific features enabled. For example, if sqlite-vec requires specific
# SQLite compile-time options, you would add them here using target_compile_definitions.
#
# Example:
# target_compile_definitions(${LIBRARY_NAME} PRIVATE SQLITE_ENABLE_FTS5)
# target_compile_definitions(${LIBRARY_NAME} PRIVATE SQLITE_DEFAULT_MEMSTATUS=0)


# --- Link system libraries (if needed) ---
# For Android, NDK provides standard libraries like 'log' for logging.
# CMake usually handles linking common C libraries.
# If you need to link against the Android log library (for __android_log_print from C):
# find_library(log-lib log)
# if (log-lib)
#     target_link_libraries(${LIBRARY_NAME} ${log-lib})
# endif()

# --- End of CMakeLists.txt ---