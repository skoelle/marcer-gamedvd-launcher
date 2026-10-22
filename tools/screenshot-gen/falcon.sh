#!/bin/sh
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.

./run.sh run --scope falcon --jobs 4
./run.sh detect --scope falcon
./run.sh run --scope falcon --retry-desktop-auto --jobs 4
./run.sh cleanup-duplicates --scope falcon
