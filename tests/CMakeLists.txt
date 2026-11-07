# Unit tests for the plugin's timer and layout logic. This is a standalone
# project with no OBS dependency; build and run it with run-tests.sh or
# run-tests.ps1 in the project root.
#
# Copyright (c) 2026 DMX Digital
# SPDX-License-Identifier: MIT

cmake_minimum_required(VERSION 3.16...3.30)

project(nixie-countdown-tests LANGUAGES C)

enable_testing()

add_executable(test-nixie-logic test-nixie-logic.c ../src/nixie-logic.c)
target_include_directories(test-nixie-logic PRIVATE ../src)
set_target_properties(test-nixie-logic PROPERTIES C_STANDARD 17 C_STANDARD_REQUIRED ON)

if(MSVC)
  target_compile_options(test-nixie-logic PRIVATE /W4 /WX)
else()
  target_compile_options(test-nixie-logic PRIVATE -Wall -Wextra -Werror)
  target_link_libraries(test-nixie-logic PRIVATE m)
endif()

add_test(NAME nixie-logic COMMAND test-nixie-logic)
