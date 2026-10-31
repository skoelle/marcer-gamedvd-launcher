#!/bin/sh
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.
set -e
cd "$(dirname "$0")"

./run.sh index --scope pd
./run.sh run --scope pd --jobs 4
./run.sh detect --scope pd
./run.sh run --scope pd --retry-desktop --jobs 4
./run.sh run --scope pd --retry-desktop-auto --jobs 8
./run.sh run --scope pd --retry-no-usable --tos 1.02 --jobs 4
./run.sh cleanup-duplicates --scope pd
./run.sh index --scope pd
