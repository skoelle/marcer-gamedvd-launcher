#!/bin/sh
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.

./run.sh run --scope pd --jobs 4
./run.sh detect --scope pd
./run.sh run --scope pd --retry-desktop --jobs 4
./run.sh run --scope pd --retry-desktop-auto --jobs 8 --force
./run.sh cleanup-duplicates --scope pd
