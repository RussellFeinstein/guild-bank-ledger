#!/usr/bin/env bash
# Run busted tests from Git Bash on Windows.
# Usage: bash run_tests.sh [busted args...]
# Example: bash run_tests.sh --verbose
#          bash run_tests.sh spec/core_spec.lua
#          bash run_tests.sh --lint   (runs luacheck instead)

LUAROCKS_DIR="/c/LuaRocks"
LUA="$LUAROCKS_DIR/lua5.1.exe"
BUSTED="C:\\LuaRocks\\systree\\lib\\luarocks\\rocks-5.1\\busted\\2.3.0-1\\bin\\busted"
LUACHECK="C:\\LuaRocks\\systree\\lib\\luarocks\\rocks-5.1\\luacheck\\1.2.0-1\\bin\\luacheck"

export PATH="$LUAROCKS_DIR:$LUAROCKS_DIR/tools:$LUAROCKS_DIR/systree/bin:$PATH"
export LUA_PATH="C:\\LuaRocks\\systree\\share\\lua\\5.1\\?.lua;C:\\LuaRocks\\systree\\share\\lua\\5.1\\?\\init.lua;;"
export LUA_CPATH="C:\\LuaRocks\\systree\\lib\\lua\\5.1\\?.dll;;"

if [[ "$1" == "--lint" ]]; then
    shift
    exec "$LUA" "$LUACHECK" "${@:-.}"
fi

exec "$LUA" \
  -e "package.path='C:\\\\LuaRocks\\\\systree\\\\share\\\\lua\\\\5.1\\\\?.lua;C:\\\\LuaRocks\\\\systree\\\\share\\\\lua\\\\5.1\\\\?\\\\init.lua;'..package.path;package.cpath='C:\\\\LuaRocks\\\\systree\\\\lib\\\\lua\\\\5.1\\\\?.dll;'..package.cpath;local k,l,_=pcall(require,'luarocks.loader') _=k and l.add_context('busted','2.3.0-1')" \
  "$BUSTED" "$@"
