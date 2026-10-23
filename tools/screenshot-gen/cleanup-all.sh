#!/bin/sh
# Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
# Licensed under the MIT License. See LICENSE file in project root for details.

./run.sh cleanup-duplicates
./run.sh cleanup-duplicates --scope falcon
./run.sh cleanup-duplicates --scope magazine
./run.sh cleanup-duplicates --scope pd
./run.sh cleanup-duplicates --scope utils
