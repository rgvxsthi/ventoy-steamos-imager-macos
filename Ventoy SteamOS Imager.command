#!/bin/bash
# Double-click this in Finder to run the imager (opens Terminal).
cd "$(dirname "$0")" || exit 1
exec ./ventoy-steamos-imager.sh
