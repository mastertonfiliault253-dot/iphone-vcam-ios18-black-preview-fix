#!/usr/bin/env bash
set -euo pipefail

: "${THEOS:?Set THEOS to your Theos installation path}"

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$project_dir"
temporary_build=""

if [[ "$project_dir" == *" "* ]]; then
    command -v rsync >/dev/null || {
        printf '%s\n' "rsync is required when the project path contains spaces." >&2
        exit 1
    }
    temporary_build="$(mktemp -d)"
    build_dir="$temporary_build/project"
    mkdir -p "$build_dir"
    rsync -a --exclude=.git --exclude=.theos --exclude=packages \
        "$project_dir/" "$build_dir/"
    trap 'rm -rf "$temporary_build"' EXIT
fi

cd "$build_dir"

make clean
make package FINALPACKAGE=1

make clean
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

if [[ -d "$THEOS/vendor/mod/roothide" || -d "$THEOS/lib/iphone/roothide" ]]; then
    make clean
    make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
else
    printf '%s\n' "RootHide Theos module not installed; rootful and rootless packages were built."
    printf '%s\n' "Install https://github.com/roothide/theos, then rerun this script for the roothide package."
fi

if [[ "$build_dir" != "$project_dir" ]]; then
    mkdir -p "$project_dir/packages"
    cp -f packages/*.deb "$project_dir/packages/"
fi
