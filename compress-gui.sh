#!/usr/bin/env bash
#
# compress-gui.sh — Zenity GUI frontend for FFmpeg video compression
#
set -euo pipefail
export LC_NUMERIC=C

# ---------- Dependencies ----------
if ! command -v zenity >/dev/null 2>&1; then
    cat <<'EOF'
This app needs 'zenity'. Install it with one of:
  Debian/Ubuntu:  sudo apt install zenity
  Fedora:         sudo dnf install zenity
  Arch:           sudo pacman -S zenity
  openSUSE:       sudo zypper install zenity
EOF
    exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    zenity --error --title="Missing ffmpeg" --width=320 \
        --text="ffmpeg was not found in your PATH.\nPlease install it and try again."
    exit 1
fi

HAVE_FFPROBE=1
command -v ffprobe >/dev/null 2>&1 || HAVE_FFPROBE=0

# ---------- Globals ----------
INPUT_FILE=""
OUTPUT_DIR=""
TARGET_W=""
TARGET_H=""
RES_LABEL=""
VBITRATE=""
USE_CRF=0
CRF=26
PRESET=""
TUNE=""
X264_PARAMS=""
THREADS=1
CODEC="libx264"
AUDIO_BITRATE="128k"

KEEP_ALL_AUDIO=0
KEEP_SURROUND=0
KEEP_SUBTITLES=0

SRC_W=""; SRC_H=""; SRC_VBITRATE=""; SRC_ABITRATE=""
SRC_DURATION=""; SRC_FRAMES=""; SRC_SIZE=0
SRC_HAS_MULTI_AUDIO=0
SRC_AUDIO_CHANNELS=""
SRC_SUB_COUNT=0

CPU_CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

TITLE="Video Compressor"

# ---------- Helpers ----------
format_time() {
    local s=$1
    if   [[ $s -lt 60   ]]; then printf '%ds' "$s"
    elif [[ $s -lt 3600 ]]; then printf '%dm%02ds' $((s/60)) $((s%60))
    else                        printf '%dh%02dm' $((s/3600)) $(((s%3600)/60))
    fi
}

human_size() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then awk -v b="$bytes" 'BEGIN{printf "%.2f GB", b/1073741824}'
    elif (( bytes >= 1048576 ));   then awk -v b="$bytes" 'BEGIN{printf "%.1f MB", b/1048576}'
    elif (( bytes >= 1024 ));      then awk -v b="$bytes" 'BEGIN{printf "%.1f KB", b/1024}'
    else printf '%d B' "$bytes"
    fi
}

# ---------- Source probe ----------
probe_source() {
    local f="$1"
    SRC_W=""; SRC_H=""; SRC_VBITRATE=""; SRC_ABITRATE=""
    SRC_DURATION=""; SRC_FRAMES=""; SRC_SIZE=0
    SRC_HAS_MULTI_AUDIO=0; SRC_AUDIO_CHANNELS=""; SRC_SUB_COUNT=0

    [[ $HAVE_FFPROBE -eq 0 ]] && return

    local dims
    dims=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
        -of csv=s=x:p=0 "$f" 2>/dev/null || true)
    if [[ "$dims" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        SRC_W="${BASH_REMATCH[1]}"; SRC_H="${BASH_REMATCH[2]}"
    fi

    SRC_DURATION=$(ffprobe -v error -show_entries format=duration \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null || echo "0")

    SRC_VBITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null || echo "")
    SRC_ABITRATE=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null || echo "")
    SRC_FRAMES=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null || echo "")

    local ac
    ac=$(ffprobe -v error -select_streams a -show_entries stream=index \
        -of csv=p=0 "$f" 2>/dev/null | grep -c . || echo 0)
    [[ "$ac" =~ ^[0-9]+$ ]] || ac=0
    (( ac > 1 )) && SRC_HAS_MULTI_AUDIO=1

    SRC_AUDIO_CHANNELS=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null || echo "")

    local sc
    sc=$(ffprobe -v error -select_streams s -show_entries stream=index \
        -of csv=p=0 "$f" 2>/dev/null | grep -c . || echo 0)
    [[ "$sc" =~ ^[0-9]+$ ]] || sc=0
    SRC_SUB_COUNT=$sc

    SRC_SIZE=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)

    if [[ ! "$SRC_VBITRATE" =~ ^[0-9]+$ || $SRC_VBITRATE -eq 0 ]]; then
        if [[ "$SRC_DURATION" =~ ^[0-9.]+$ && $SRC_SIZE -gt 0 ]]; then
            local a="${SRC_ABITRATE:-0}"
            [[ ! "$a" =~ ^[0-9]+$ ]] && a=0
            SRC_VBITRATE=$(awk -v s="$SRC_SIZE" -v d="$SRC_DURATION" -v a="$a" \
                'BEGIN{ v=(s*8/d)-a; if(v<0) v=0; printf "%d", v }')
        fi
    fi

    if [[ ! "$SRC_FRAMES" =~ ^[0-9]+$ || $SRC_FRAMES -eq 0 ]]; then
        local fps_str
        fps_str=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
            -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null || echo "")
        if [[ "$fps_str" =~ ^([0-9]+)/([0-9]+)$ ]]; then
            local n="${BASH_REMATCH[1]}" d="${BASH_REMATCH[2]}"
            [[ "$d" == "0" ]] && d=1
            SRC_FRAMES=$(awk -v dur="$SRC_DURATION" -v n="$n" -v d="$d" \
                'BEGIN{ printf "%d", dur*n/d }')
        fi
    fi
}

source_info_text() {
    local t=""
    [[ -n "$SRC_W" ]] && t+="Resolution: ${SRC_W}×${SRC_H}\n"
    if [[ "$SRC_VBITRATE" =~ ^[0-9]+$ && $SRC_VBITRATE -gt 0 ]]; then
        t+="Video: ~$(( SRC_VBITRATE / 1000 )) kbps\n"
    fi
    if [[ "$SRC_ABITRATE" =~ ^[0-9]+$ && $SRC_ABITRATE -gt 0 ]]; then
        t+="Audio: ~$(( SRC_ABITRATE / 1000 )) kbps"
        [[ -n "$SRC_AUDIO_CHANNELS" ]] && t+=" ($SRC_AUDIO_CHANNELS ch)"
        t+="\n"
    fi
    (( SRC_HAS_MULTI_AUDIO == 1 )) && t+="Audio tracks: multiple\n"
    (( SRC_SUB_COUNT > 0 )) && t+="Subtitles: $SRC_SUB_COUNT stream(s)\n"
    [[ "$SRC_DURATION" =~ ^[0-9.]+$ ]] && t+="Duration: $(printf '%.1f' "$SRC_DURATION")s\n"
    [[ "$SRC_FRAMES" =~ ^[0-9]+$ && $SRC_FRAMES -gt 0 ]] && t+="Frames: $SRC_FRAMES\n"
    (( SRC_SIZE > 0 )) && t+="Size: $(human_size "$SRC_SIZE")\n"
    printf '%b' "$t"
}

# ---------- Dialog: pick file ----------
pick_file() {
    local f
    f=$(zenity --file-selection --title="$TITLE — choose input video" \
        --file-filter="Video files | *.mp4 *.mkv *.mov *.avi *.webm *.flv *.wmv *.m4v *.mpg *.mpeg *.ts *.m2ts *.3gp *.ogv" \
        --file-filter="All files | *" 2>/dev/null) || return 1
    [[ -z "$f" ]] && return 1
    INPUT_FILE="$f"
    return 0
}

# ---------- Dialog: speed profile ----------
pick_speed() {
    local rec="FALSE"
    (( CPU_CORES <= 2 )) && rec="TRUE"

    local choice
    choice=$(zenity --list --radiolist \
        --title="$TITLE — encoding speed" \
        --text="Detected $CPU_CORES CPU core(s). Choose a speed profile:" \
        --column="" --column="Profile" --column="Description" \
        "$rec"   "Fast"     "~5-10× faster, larger files (netbook-friendly)" \
        "FALSE"  "Balanced" "Good compromise" \
        "FALSE"  "Quality"  "Smallest files, slowest" \
        --width=520 --height=260 2>/dev/null) || return 1
    [[ -z "$choice" ]] && return 1

    case "$choice" in
        Fast)
            PRESET="ultrafast"; TUNE="fastdecode"
            X264_PARAMS="rc-lookahead=10:ref=1:bframes=0:me=dia:subme=1:trellis=0:8x8dct=0:mixed-refs=0:weightp=0:sliced-threads=1"
            ;;
        Balanced)
            PRESET="superfast"; TUNE=""
            X264_PARAMS="rc-lookahead=20:ref=2:sliced-threads=1"
            ;;
        Quality)
            PRESET="veryfast"; TUNE=""
            X264_PARAMS=""
            ;;
        *) return 1 ;;
    esac
    THREADS="$CPU_CORES"
    (( THREADS < 1 )) && THREADS=1
    return 0
}

# ---------- Dialog: resolution ----------
pick_resolution() {
    local choice
    choice=$(zenity --list --radiolist \
        --title="$TITLE — target resolution" \
        --text="Choose target resolution:" \
        --column="" --column="Res" --column="Dimensions" \
        "TRUE"  "720p"   "1280×720" \
        "FALSE" "480p"   "854×480" \
        "FALSE" "360p"   "640×360" \
        "FALSE" "Custom" "Enter dimensions manually" \
        --width=380 --height=280 2>/dev/null) || return 1
    [[ -z "$choice" ]] && return 1

    case "$choice" in
        720p) TARGET_W=1280; TARGET_H=720; RES_LABEL="720p"; DEFAULT_VBITRATE=2500; CRF=24 ;;
        480p) TARGET_W=854;  TARGET_H=480; RES_LABEL="480p"; DEFAULT_VBITRATE=1000; CRF=26 ;;
        360p) TARGET_W=640;  TARGET_H=360; RES_LABEL="360p"; DEFAULT_VBITRATE=600;  CRF=28 ;;
        Custom)
            local w h
            w=$(zenity --entry --title="$TITLE — custom width" \
                --text="Width (px, e.g. 1024):" --entry-text="1024" 2>/dev/null) || return 1
            [[ -z "$w" ]] && return 1
            h=$(zenity --entry --title="$TITLE — custom height" \
                --text="Height (px, e.g. 576):" --entry-text="576" 2>/dev/null) || return 1
            [[ -z "$h" ]] && return 1
            if ! [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]]; then
                zenity --error --title="$TITLE" --text="Width and height must be whole numbers." --width=280
                return 1
            fi
            TARGET_W="$w"; TARGET_H="$h"; RES_LABEL="${h}p"
            DEFAULT_VBITRATE=$(( (w * h) / 350 ))
            (( DEFAULT_VBITRATE < 300 )) && DEFAULT_VBITRATE=300
            CRF=26
            ;;
        *) return 1 ;;
    esac
    return 0
}

# ---------- Dialog: bitrate ----------
pick_bitrate() {
    # Cap default at 75% of source
    local src_kbps=0
    if [[ "$SRC_VBITRATE" =~ ^[0-9]+$ && $SRC_VBITRATE -gt 0 ]]; then
        src_kbps=$(( SRC_VBITRATE / 1000 ))
        local cap=$(( src_kbps * 3 / 4 ))
        (( cap < DEFAULT_VBITRATE )) && DEFAULT_VBITRATE=$cap
    fi

    while true; do
        local input
        input=$(zenity --entry \
            --title="$TITLE — video bitrate" \
            --text="Video bitrate in kbps.\n\nBlank = default ($DEFAULT_VBITRATE kbps)\nType 'auto' for quality-based CRF $CRF" \
            --entry-text="" --width=420 2>/dev/null) || return 1

        if [[ -z "$input" ]]; then
            VBITRATE="$DEFAULT_VBITRATE"; USE_CRF=0; return 0
        elif [[ "$input" == "auto" || "$input" == "0" ]]; then
            USE_CRF=1; VBITRATE=0; return 0
        elif [[ "$input" =~ ^[0-9]+$ ]]; then
            VBITRATE="$input"; USE_CRF=0
            if (( src_kbps > 0 && VBITRATE >= src_kbps )); then
                if zenity --question --title="$TITLE" --width=380 \
                    --text="Target ${VBITRATE}k ≥ source ${src_kbps}k.\nThe output may be LARGER than the input.\n\nContinue anyway?"; then
                    return 0
                else
                    continue
                fi
            fi
            return 0
        else
            zenity --error --title="$TITLE" --text="Enter a number, 'auto', or leave blank." --width=320
        fi
    done
}

# ---------- Dialog: audio/subtitle options ----------
pick_options() {
    KEEP_ALL_AUDIO=0; KEEP_SURROUND=0; KEEP_SUBTITLES=0; AUDIO_BITRATE="128k"

    if (( SRC_HAS_MULTI_AUDIO == 1 )); then
        if zenity --question --title="$TITLE" --width=400 \
            --text="The source has multiple audio tracks.\n\nKeep all of them?"; then
            KEEP_ALL_AUDIO=1
        fi
    fi

    if [[ "$SRC_AUDIO_CHANNELS" =~ ^[0-9]+$ && $SRC_AUDIO_CHANNELS -gt 2 ]]; then
        if zenity --question --title="$TITLE" --width=400 \
            --text="Source audio is $SRC_AUDIO_CHANNELS-channel surround.\n\nKeep surround?\n(Choosing 'No' downmixes to stereo.)"; then
            KEEP_SURROUND=1
            AUDIO_BITRATE="384k"
        fi
    fi

    if (( SRC_SUB_COUNT > 0 )); then
        if zenity --question --title="$TITLE" --width=420 \
            --text="Source has $SRC_SUB_COUNT subtitle stream(s).\n\nKeep them?\n(Choosing 'Yes' switches output to .mkv — MP4 can't hold these subs.)"; then
            KEEP_SUBTITLES=1
        fi
    fi
}

# ---------- Dialog: output directory ----------
pick_output() {
    local d
    d=$(zenity --file-selection --directory \
        --title="$TITLE — choose output folder" 2>/dev/null) || return 1
    [[ -z "$d" ]] && return 1
    if ! mkdir -p "$d" 2>/dev/null; then
        zenity --error --title="$TITLE" --text="Could not create: $d" --width=320
        return 1
    fi
    OUTPUT_DIR="$d"
    return 0
}

# ---------- Dialog: confirm ----------
confirm() {
    local ext="mp4"; (( KEEP_SUBTITLES == 1 )) && ext="mkv"
    local br
    if (( USE_CRF == 1 )); then br="auto (CRF $CRF)"; else br="${VBITRATE} kbps"; fi
    local audio_desc="stereo"
    (( KEEP_SURROUND == 1 )) && audio_desc="surround ($AUDIO_BITRATE)"
    local audio_trk="main only"; (( KEEP_ALL_AUDIO == 1 )) && audio_trk="all tracks"
    local sub_desc="dropped"; (( KEEP_SUBTITLES == 1 )) && sub_desc="$SRC_SUB_COUNT kept"

    zenity --question --title="$TITLE — confirm" --width=520 \
        --text="Ready to encode:

Resolution: $RES_LABEL (max ${TARGET_W}×${TARGET_H})
Bitrate:    $br
Speed:      $PRESET ($THREADS thread(s))
Audio:      $audio_desc, $audio_trk
Subtitles:  $sub_desc
Container:  .$ext

Output folder:
$OUTPUT_DIR

Proceed?"
}

# ---------- Compression with progress ----------
do_compress() {
    local ext="mp4"; (( KEEP_SUBTITLES == 1 )) && ext="mkv"

    local base out
    base="$(basename "$INPUT_FILE")"
    out="$OUTPUT_DIR/${base%.*}.${ext}"
    if [[ -e "$out" ]]; then
        out="$OUTPUT_DIR/${base%.*}_compressed.${ext}"
        local n=1
        while [[ -e "$out" ]]; do
            out="$OUTPUT_DIR/${base%.*}_compressed_${n}.${ext}"
            n=$((n+1))
        done
    fi

    local scale_filter
    scale_filter="scale='min(${TARGET_W},iw)':'min(${TARGET_H},ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"

    # Audio cap
    local target_audio="$AUDIO_BITRATE"
    if [[ "$SRC_ABITRATE" =~ ^[0-9]+$ && $SRC_ABITRATE -gt 0 ]]; then
        local src_a_kbps=$(( SRC_ABITRATE / 1000 ))
        local chosen_a_kbps="${AUDIO_BITRATE%k}"
        if (( src_a_kbps < 64 )); then target_audio="64k"
        elif (( src_a_kbps < chosen_a_kbps )); then target_audio="${src_a_kbps}k"
        fi
    fi

    local -a cmd=(ffmpeg -hide_banner -loglevel error -nostats -progress pipe:1 -y
        -i "$INPUT_FILE"
    )

    if (( KEEP_SUBTITLES == 1 )); then
        if (( KEEP_ALL_AUDIO == 1 )); then
            cmd+=(-map 0:v:0 -map 0:a -map 0:s?)
        else
            cmd+=(-map 0:v:0 -map 0:a:0 -map 0:s?)
        fi
    else
        if (( KEEP_ALL_AUDIO == 1 )); then
            cmd+=(-map 0:v:0 -map 0:a)
        fi
    fi

    cmd+=(-vf "$scale_filter"
        -c:v "$CODEC" -preset "$PRESET" -threads "$THREADS"
    )
    [[ -n "$TUNE" ]] && cmd+=(-tune "$TUNE")
    if [[ "$CODEC" == "libx264" && -n "$X264_PARAMS" ]]; then
        cmd+=(-x264-params "$X264_PARAMS")
    fi

    if (( USE_CRF == 1 )); then
        cmd+=(-crf "$CRF")
    else
        cmd+=(-b:v "${VBITRATE}k" -maxrate "$(( VBITRATE*3/2 ))k" -bufsize "$(( VBITRATE*2 ))k")
    fi

    cmd+=(-pix_fmt yuv420p)

    if (( KEEP_SURROUND == 1 )); then
        cmd+=(-c:a aac -strict -2 -b:a "$target_audio")
    else
        cmd+=(-c:a aac -strict -2 -b:a "$target_audio" -ac 2)
    fi

    (( KEEP_SUBTITLES == 1 )) && cmd+=(-c:s copy)
    [[ "$ext" == "mp4" ]] && cmd+=(-movflags +faststart)
    cmd+=("$out")

    local total_frames="${SRC_FRAMES:-0}"
    [[ ! "$total_frames" =~ ^[0-9]+$ ]] && total_frames=0

    local errfile start_ts ff_status
    errfile=$(mktemp)
    start_ts=$(date +%s)

    # Run ffmpeg with progress piped to zenity
    set +e
    "${cmd[@]}" 2>"$errfile" \
    | awk -v total="$total_frames" '
        BEGIN { last = -1 }
        /^frame=/ {
            f = $0; sub(/^frame=/, "", f); f = f + 0
            if (total > 0) {
                p = int(f * 100 / total)
                if (p > 99) p = 99
                if (p != last) {
                    print p
                    printf "# Encoding: frame %d of %d\n", f, total
                    fflush()
                    last = p
                }
            }
        }
        /^progress=end/ { print 100; print "# Finalizing..."; fflush(); exit }
        END { print 100; fflush() }
    ' \
    | zenity --progress --title="$TITLE — encoding" \
        --text="Starting ffmpeg..." --percentage=0 --auto-close --width=440
    ff_status=${PIPESTATUS[0]}
    set -e

    local end; end=$(date +%s)

    if (( ff_status != 0 )); then
        local err_text=""
        [[ -s "$errfile" ]] && err_text=$(tail -c 1500 "$errfile")
        rm -f "$errfile"
        zenity --error --title="$TITLE — ffmpeg failed" --width=560 \
            --text="FFmpeg exited with code $ff_status.\n\n$err_text"
        return 1
    fi
    rm -f "$errfile"

    local insz outsz ratio arrow
    insz=$(stat -c%s "$INPUT_FILE" 2>/dev/null || stat -f%z "$INPUT_FILE")
    outsz=$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out")
    ratio=$(awk -v a="$insz" -v b="$outsz" 'BEGIN{ if(a>0) printf "%.1f", (1-b/a)*100; else print "0" }')
    arrow="smaller"
    (( outsz > insz )) && arrow="LARGER — source was already well compressed"

    zenity --info --title="$TITLE — done" --width=480 \
        --text="Encoding finished in $(format_time $((end-start_ts))).

Input:  $(human_size "$insz")
Output: $(human_size "$outsz")
Change: ${ratio}% $arrow

Saved to:
$out"
}

# ---------- Main ----------
while true; do
    # Reset per-file state
    KEEP_ALL_AUDIO=0; KEEP_SURROUND=0; KEEP_SUBTITLES=0
    AUDIO_BITRATE="128k"

    if ! pick_file; then
        exit 0
    fi

    probe_source "$INPUT_FILE"

    if [[ $HAVE_FFPROBE -eq 1 ]]; then
        zenity --info --title="$TITLE — source info" --width=460 \
            --text="File: $(basename "$INPUT_FILE")

$(source_info_text)" || exit 0
    fi

    if ! pick_speed;      then continue; fi
    if ! pick_resolution; then continue; fi
    if ! pick_bitrate;    then continue; fi
    pick_options
    if ! pick_output;     then continue; fi
    if ! confirm;         then continue; fi

    do_compress || true

    if ! zenity --question --title="$TITLE" --width=340 \
        --text="Compress another video?"; then
        break
    fi
done

exit 0
