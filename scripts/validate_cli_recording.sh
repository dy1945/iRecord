#!/bin/bash
set -euo pipefail

VIDEO="$1"
EXPECTED_DIR="$2"
MAX_EDGE="${3:-1920}"

actual_dir="$(dirname "$VIDEO")"
[[ "$actual_dir" == "$EXPECTED_DIR" ]] || {
  echo "FAIL output directory: $actual_dir (expected $EXPECTED_DIR)"
  exit 1
}

dimensions="$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height -of csv=p=0 "$VIDEO")"
width="${dimensions%,*}"
height="${dimensions#*,}"
(( width <= MAX_EDGE && height <= MAX_EDGE )) || {
  echo "FAIL dimensions: ${width}x${height} (max edge $MAX_EDGE)"
  exit 1
}

scene_count="$(ffmpeg -i "$VIDEO" \
  -vf "fps=1,scale=320:-1,select='gt(scene,0.02)',showinfo" \
  -fps_mode vfr -f null - 2>&1 | awk '/Parsed_showinfo.* n:/{count++} END{print count+0}')"
(( scene_count >= 2 )) || {
  echo "FAIL visual activity: only $scene_count meaningful scene changes"
  exit 1
}

echo "PASS directory=$actual_dir dimensions=${width}x${height} scene_changes=$scene_count"
