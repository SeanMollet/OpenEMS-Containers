#!/bin/bash
# usage: build.sh [dev|dev-amd|runtime|runtime-amd|nvidia|amd|all] [openEMS-Project dir]
#   -- build the images (default: all). The GPU engine is HIP and there is an image per
#   vendor: dev/runtime carry CUDA, dev-amd/runtime-amd carry ROCm.
# The openEMS sources: the given directory, else an openEMS-Project tree next to this
# directory (../openEMS-Project, or the tree this directory is in), else the GPU branch on GitHub.
set -e
cd "$(dirname "$0")"
TARGET=${1:-all}
src_ok() { [ -d "$1/fparser" ] && [ -d "$1/CSXCAD" ] && [ -d "$1/openEMS" ] && [ -d "$1/.git/modules" ]; }
SRC=
for d in "$2" ../openEMS-Project ../../..; do
	if [ -n "$d" ] && src_ok "$d"; then SRC=$(cd "$d" && pwd); break; fi
done
if [ -n "$SRC" ]; then
	echo "build.sh: openEMS sources from $SRC"
	SOURCE=(--build-arg OPENEMS_SOURCE=local --build-context openems-src="$SRC")
else
	echo "build.sh: openEMS sources from GitHub"
	SOURCE=(--build-arg OPENEMS_SOURCE=github)
fi
want() {   # want <target>: is this target one of the ones asked for?
	case $TARGET in
		all) return 0;;
		nvidia) [ "$1" = dev ] || [ "$1" = runtime ];;
		amd) [ "$1" = dev-amd ] || [ "$1" = runtime-amd ];;
		*) [ "$1" = "$TARGET" ];;
	esac
}
want dev         && docker build --target dev         -t seanmollet/openems-dev:latest .
want dev-amd     && docker build --target dev-amd     -t seanmollet/openems-dev-amd:latest .
want runtime     && docker build --target runtime     "${SOURCE[@]}" -t seanmollet/openems:latest .
want runtime-amd && docker build --target runtime-amd "${SOURCE[@]}" -t seanmollet/openems-amd:latest .
exit 0
