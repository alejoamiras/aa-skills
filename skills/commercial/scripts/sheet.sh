#!/usr/bin/env bash
# Contact sheet of a clip: 8 evenly spaced frames in a row, for reviewing a take as one image.
set -euo pipefail
in="$1"; out="${2:-${in%.*}-sheet.jpg}"
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in")
fps=$(bun -e "console.log((8 / $dur).toFixed(4))")
ffmpeg -v error -y -i "$in" -vf "fps=$fps,scale=480:-2,tile=4x2" -frames:v 1 -q:v 4 "$out"
echo "$out"
