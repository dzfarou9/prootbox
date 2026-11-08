cmake_minimum_required(VERSION 3.18.1)

project(prootbox_pty C)

add_library(prootbox_pty SHARED pty_spawn.c)

target_compile_options(prootbox_pty PRIVATE -Wall -Wextra -O2)

# liblog is optional: nothing is logged from C so no link is required.
