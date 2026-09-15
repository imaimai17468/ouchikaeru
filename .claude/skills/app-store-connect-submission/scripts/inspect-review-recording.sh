#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <review-recording.mov-or-mp4>" >&2
    exit 64
fi

recording_path=$1
if [ ! -f "$recording_path" ]; then
    echo "Recording not found: $recording_path" >&2
    exit 66
fi

for required_command in ffprobe ffmpeg; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "Required command is unavailable: $required_command" >&2
        exit 69
    fi
done

inspection_dir=$(mktemp -d "${TMPDIR:-/tmp}/app-review-recording.XXXXXX")
opening_sheet="$inspection_dir/opening-first-nine-seconds.jpg"
overview_sheet="$inspection_dir/overview-ten-second-intervals.jpg"

ffprobe -v error \
    -show_entries format=filename,duration,size:stream=index,codec_type,codec_name,width,height,r_frame_rate \
    -of json "$recording_path"

ffmpeg -v error -y -i "$recording_path" \
    -vf "fps=1,scale=359:-1,tile=3x3" -frames:v 1 -update 1 "$opening_sheet"
ffmpeg -v error -y -i "$recording_path" \
    -vf "fps=1/10,scale=359:-1,tile=3x3" -frames:v 1 -update 1 "$overview_sheet"

echo "Opening contact sheet: $opening_sheet"
echo "Overview contact sheet: $overview_sheet"
