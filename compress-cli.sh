#!/usr/bin/env bash
#
# compress.sh — Interactive video compressor using FFmpeg
#
set -euo pipefail

# Force C locale for numeric formatting (avoids "invalid number" on tr_TR, de_DE, etc.)
export LC_NUMERIC=C

# ---------- Colors ----------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_CYN=$'\033[36m'; C_BLD=$'\033[1m'
    C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""; C_BLD=""; C_DIM=""; C_RST=""
fi

log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }

# ---------- Globals ----------
INPUT_FILE=""
OUTPUT_DIR=""
TARGET_W=""
TARGET_H=""
RES_LABEL=""
DEFAULT_VBITRATE=0
VBITRATE=""
USE_CRF=0
CRF=26
PRESET="medium"
CODEC="libx264"
AUDIO_BITRATE="128k"
HAVE_FFPROBE=1

# Speed profile
CPU_CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
SPEED_PROFILE="balanced"
TUNE=""
X264_PARAMS=""
THREADS=1

# Audio/subtitle handling
KEEP_ALL_AUDIO=0
KEEP_SURROUND=0
KEEP_SUBTITLES=0

# Source info
SRC_W=""; SRC_H=""; SRC_VBITRATE=""; SRC_ABITRATE=""
SRC_DURATION=""; SRC_FRAMES=""; SRC_SIZE=0
SRC_HAS_MULTI_AUDIO=0
SRC_AUDIO_CHANNELS=""
SRC_SUB_COUNT=0

# ---------- Helpers ----------
expand_path() {
    local p="$1"
    p="${p/#\~/$HOME}"
    printf '%s' "$p"
}

banner() {
    printf '%s%s' "$C_CYN" "$C_BLD"
    cat <<'EOF'
  ╔════════════════════════════════════════════╗
  ║        Video Compressor  (FFmpeg)          ║
  ╚════════════════════════════════════════════╝
EOF
    printf '%s\n' "$C_RST"
}

format_time() {
    local s=$1
    if   [[ $s -lt 60   ]]; then printf '%ds' "$s"
    elif [[ $s -lt 3600 ]]; then printf '%dm%02ds' $((s/60)) $((s%60))
    else                        printf '%dh%02dm' $((s/3600)) $(((s%3600)/60))
    fi
}

# ---------- Source probing ----------
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
        SRC_W="${BASH_REMATCH[1]}"
        SRC_H="${BASH_REMATCH[2]}"
    fi

    SRC_DURATION=$(ffprobe -v error -show_entries format=duration \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null || echo "0")

    SRC_VBITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null || echo "")
    SRC_ABITRATE=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null || echo "")
    SRC_FRAMES=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null || echo "")

    local audio_count
    audio_count=$(ffprobe -v error -select_streams a -show_entries stream=index \
        -of csv=p=0 "$f" 2>/dev/null | grep -c . || echo 0)
    [[ "$audio_count" =~ ^[0-9]+$ ]] || audio_count=0
    (( audio_count > 1 )) && SRC_HAS_MULTI_AUDIO=1

    SRC_AUDIO_CHANNELS=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null || echo "")

    local sub_count
    sub_count=$(ffprobe -v error -select_streams s -show_entries stream=index \
        -of csv=p=0 "$f" 2>/dev/null | grep -c . || echo 0)
    [[ "$sub_count" =~ ^[0-9]+$ ]] || sub_count=0
    SRC_SUB_COUNT=$sub_count

    SRC_SIZE=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)

    # Fallback: compute video bitrate from filesize/duration
    if [[ ! "$SRC_VBITRATE" =~ ^[0-9]+$ || $SRC_VBITRATE -eq 0 ]]; then
        if [[ "$SRC_DURATION" =~ ^[0-9.]+$ && $SRC_SIZE -gt 0 ]]; then
            local a="${SRC_ABITRATE:-0}"
            [[ ! "$a" =~ ^[0-9]+$ ]] && a=0
            SRC_VBITRATE=$(awk -v s="$SRC_SIZE" -v d="$SRC_DURATION" -v a="$a" \
                'BEGIN{ v=(s*8/d)-a; if(v<0) v=0; printf "%d", v }')
        fi
    fi

    # Fallback: compute frame count from duration * fps
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

show_source_info() {
    [[ $HAVE_FFPROBE -eq 0 ]] && return
    printf '%s  Source info:%s\n' "$C_DIM" "$C_RST"
    if [[ -n "$SRC_W" ]]; then
        printf '    Resolution: %s\n' "${SRC_W}×${SRC_H}"
    fi
    if [[ "$SRC_VBITRATE" =~ ^[0-9]+$ && $SRC_VBITRATE -gt 0 ]]; then
        printf '    Video:      ~%s kbps\n' $(( SRC_VBITRATE / 1000 ))
    fi
    if [[ "$SRC_ABITRATE" =~ ^[0-9]+$ && $SRC_ABITRATE -gt 0 ]]; then
        printf '    Audio:      ~%s kbps' $(( SRC_ABITRATE / 1000 ))
        [[ -n "$SRC_AUDIO_CHANNELS" ]] && printf ' (%s ch)' "$SRC_AUDIO_CHANNELS"
        printf '\n'
    fi
    (( SRC_HAS_MULTI_AUDIO == 1 )) && printf '    Audio tracks: multiple\n'
    (( SRC_SUB_COUNT > 0 )) && printf '    Subtitles:    %s stream(s)\n' "$SRC_SUB_COUNT"
    if [[ "$SRC_DURATION" =~ ^[0-9.]+$ ]]; then
        printf '    Duration:   %.1fs\n' "$SRC_DURATION"
    fi
    if [[ "$SRC_FRAMES" =~ ^[0-9]+$ && $SRC_FRAMES -gt 0 ]]; then
        printf '    Frames:     %s\n' "$SRC_FRAMES"
    fi
    if [[ $SRC_SIZE -gt 0 ]]; then
        printf '    Size:       %s\n' "$(du -h "$INPUT_FILE" | cut -f1)"
    fi
    echo
}

# ---------- Prompt: input file ----------
prompt_input_file() {
    local path
    while true; do
        printf '%sInput video file (or "q" to quit):%s ' "$C_BLD" "$C_RST"
        IFS= read -r path || exit 0
        [[ "$path" == "q" || "$path" == "Q" ]] && { echo; ok "Goodbye."; exit 0; }
        path="$(expand_path "$path")"
        if [[ -z "$path" ]]; then
            warn "Please enter a path."
        elif [[ -f "$path" ]]; then
            INPUT_FILE="$path"
            return 0
        else
            err "Not a file: $path"
        fi
    done
}

# ---------- Prompt: speed profile ----------
prompt_speed_profile() {
    echo
    printf '%sEncoding speed profile%s (detected %s CPU core(s))\n' \
        "$C_BLD" "$C_RST" "$CPU_CORES"
    printf '  1) %sFast%s       netbook-friendly (~5–10× faster, larger files)\n' \
        "$C_GRN" "$C_RST"
    printf '  2) %sBalanced%s   good compromise\n' "$C_GRN" "$C_RST"
    printf '  3) %sQuality%s    smallest files, slowest\n' "$C_GRN" "$C_RST"
    (( CPU_CORES <= 2 )) && printf '  %s→ Recommend "1" on this machine.%s\n' \
        "$C_YEL" "$C_RST"

    local c
    while true; do
        printf '%s> %s' "$C_BLD" "$C_RST"
        IFS= read -r c || exit 0
        case "$c" in
            1|"") SPEED_PROFILE="fast";     break ;;
            2)    SPEED_PROFILE="balanced"; break ;;
            3)    SPEED_PROFILE="quality";  break ;;
            *) err "Pick 1–3." ;;
        esac
    done

    case "$SPEED_PROFILE" in
        fast)
            PRESET="ultrafast"
            TUNE="fastdecode"
            X264_PARAMS="rc-lookahead=10:ref=1:bframes=0:me=dia:subme=1:trellis=0:8x8dct=0:mixed-refs=0:weightp=0:sliced-threads=1"
            ;;
        balanced)
            PRESET="superfast"
            TUNE=""
            X264_PARAMS="rc-lookahead=20:ref=2:sliced-threads=1"
            ;;
        quality)
            PRESET="veryfast"
            TUNE=""
            X264_PARAMS=""
            ;;
    esac
    THREADS="$CPU_CORES"
    (( THREADS < 1 )) && THREADS=1
}

# ---------- Prompt: resolution ----------
prompt_resolution() {
    echo
    printf '%sChoose target resolution:%s\n' "$C_BLD" "$C_RST"
    printf '  1) %s720p%s  (1280×720)\n' "$C_GRN" "$C_RST"
    printf '  2) %s480p%s  (854×480)\n'  "$C_GRN" "$C_RST"
    printf '  3) %s360p%s  (640×360)\n'  "$C_GRN" "$C_RST"
    printf '  4) Custom\n'

    local choice
    while true; do
        printf '%s> %s' "$C_BLD" "$C_RST"
        IFS= read -r choice || exit 0
        case "$choice" in
            1) TARGET_W=1280; TARGET_H=720; RES_LABEL="720p"; DEFAULT_VBITRATE=2500; CRF=24; return 0 ;;
            2) TARGET_W=854;  TARGET_H=480; RES_LABEL="480p"; DEFAULT_VBITRATE=1000; CRF=26; return 0 ;;
            3) TARGET_W=640;  TARGET_H=360; RES_LABEL="360p"; DEFAULT_VBITRATE=600;  CRF=28; return 0 ;;
            4)
                local w h
                printf '  Width:  '; IFS= read -r w
                printf '  Height: '; IFS= read -r h
                if [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]]; then
                    TARGET_W="$w"; TARGET_H="$h"; RES_LABEL="${h}p"
                    DEFAULT_VBITRATE=$(( (w * h) / 350 ))
                    (( DEFAULT_VBITRATE < 300 )) && DEFAULT_VBITRATE=300
                    CRF=26
                    return 0
                fi
                err "Width and height must be numbers."
                ;;
            *) err "Pick 1–4." ;;
        esac
    done
}

# ---------- Prompt: bitrate ----------
prompt_bitrate() {
    local src_kbps=0
    if [[ "$SRC_VBITRATE" =~ ^[0-9]+$ && $SRC_VBITRATE -gt 0 ]]; then
        src_kbps=$(( SRC_VBITRATE / 1000 ))
        local cap=$(( src_kbps * 3 / 4 ))
        if [[ $cap -lt $DEFAULT_VBITRATE ]]; then
            printf '%s' "$C_YEL"
            printf '  Source is only ~%d kbps video. Capping default from %d → %d kbps.\n' \
                "$src_kbps" "$DEFAULT_VBITRATE" "$cap"
            printf '%s' "$C_RST"
            DEFAULT_VBITRATE=$cap
        fi
    fi

    echo
    printf '%sVideo bitrate in kbps%s\n' "$C_BLD" "$C_RST"
    printf '  Default: %s kbps   (type %sauto%s for quality-based CRF %s)\n' \
        "$DEFAULT_VBITRATE" "$C_GRN" "$C_RST" "$CRF"
    printf '%s> %s' "$C_BLD" "$C_RST"

    local input
    IFS= read -r input || exit 0
    if [[ -z "$input" ]]; then
        VBITRATE="$DEFAULT_VBITRATE"
        USE_CRF=0
    elif [[ "$input" == "auto" || "$input" == "0" ]]; then
        USE_CRF=1
        VBITRATE=0
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        VBITRATE="$input"
        USE_CRF=0
        if [[ $src_kbps -gt 0 && $VBITRATE -ge $src_kbps ]]; then
            warn "Target ${VBITRATE}k ≥ source ${src_kbps}k — output may be BIGGER."
            printf 'Continue anyway? [y/N] '
            local c
            IFS= read -r c || exit 0
            if [[ ! "$c" =~ ^[yY] ]]; then
                prompt_bitrate
                return
            fi
        fi
    else
        err "Enter a number, 'auto', or hit Enter for default."
        prompt_bitrate
    fi
}

# ---------- Prompt: audio options ----------
prompt_audio_options() {
    echo
    if (( SRC_HAS_MULTI_AUDIO == 1 )); then
        printf '%sSource has multiple audio tracks.%s Keep all of them? [y/N] ' \
            "$C_YEL" "$C_RST"
        local c
        IFS= read -r c || exit 0
        [[ "$c" =~ ^[yY] ]] && KEEP_ALL_AUDIO=1 || KEEP_ALL_AUDIO=0
    fi

    if [[ "$SRC_AUDIO_CHANNELS" =~ ^[0-9]+$ && $SRC_AUDIO_CHANNELS -gt 2 ]]; then
        printf '%sSource audio is %s-channel surround.%s Keep surround? [y/N] ' \
            "$C_YEL" "$SRC_AUDIO_CHANNELS" "$C_RST"
        local c
        IFS= read -r c || exit 0
        if [[ "$c" =~ ^[yY] ]]; then
            KEEP_SURROUND=1
            AUDIO_BITRATE="384k"
            printf '  → Keeping surround, audio bitrate bumped to 384k.\n'
        else
            KEEP_SURROUND=0
        fi
    fi
}

# ---------- Prompt: subtitle options ----------
prompt_subtitle_options() {
    if (( SRC_SUB_COUNT > 0 )); then
        echo
        printf '%sSource has %s subtitle stream(s).%s Keep them? [y/N] ' \
            "$C_YEL" "$SRC_SUB_COUNT" "$C_RST"
        local c
        IFS= read -r c || exit 0
        if [[ "$c" =~ ^[yY] ]]; then
            KEEP_SUBTITLES=1
            printf '  → Output will be %s.mkv%s (MP4 can'\''t hold these subs).\n' \
                "$C_GRN" "$C_RST"
        else
            KEEP_SUBTITLES=0
        fi
    fi
}

# ---------- Prompt: output ----------
prompt_output_dir() {
    echo
    printf '%sOutput directory%s [default: ./compressed]: ' "$C_BLD" "$C_RST"
    local out
    IFS= read -r out || exit 0
    out="$(expand_path "$out")"
    [[ -z "$out" ]] && out="./compressed"

    if [[ -e "$out" && ! -d "$out" ]]; then
        err "Path exists but is not a directory: $out"
        prompt_output_dir
        return
    fi
    if ! mkdir -p "$out" 2>/dev/null; then
        err "Could not create directory: $out"
        prompt_output_dir
        return
    fi
    OUTPUT_DIR="$out"
}

# ---------- Confirm ----------
confirm_summary() {
    local container="mp4"
    (( KEEP_SUBTITLES == 1 )) && container="mkv"

    echo
    printf '%s──────────────── Summary ────────────────%s\n' "$C_DIM" "$C_RST"
    printf '  Input:      %s\n' "$INPUT_FILE"
    printf '  Resolution: %s (max %s×%s)\n' "$RES_LABEL" "$TARGET_W" "$TARGET_H"
    if [[ $USE_CRF -eq 1 ]]; then
        printf '  Bitrate:    auto (CRF %s)\n' "$CRF"
    else
        printf '  Bitrate:    %s kbps\n' "$VBITRATE"
    fi
    if (( KEEP_SURROUND == 1 )); then
        printf '  Audio:      %s, surround preserved\n' "$AUDIO_BITRATE"
    else
        printf '  Audio:      %s, downmixed to stereo\n' "$AUDIO_BITRATE"
    fi
    if (( KEEP_ALL_AUDIO == 1 )); then
        printf '  Audio trk:  all tracks kept\n'
    else
        printf '  Audio trk:  main track only\n'
    fi
    if (( KEEP_SUBTITLES == 1 )); then
        printf '  Subtitles:  copied (%s stream(s))\n' "$SRC_SUB_COUNT"
    else
        printf '  Subtitles:  dropped\n'
    fi
    printf '  Container:  .%s\n' "$container"
    printf '  Pixel fmt:  yuv420p (universal playback)\n'
    printf '  Codec:      %s (preset %s, %s core(s))\n' "$CODEC" "$PRESET" "$THREADS"
    printf '  Output dir: %s\n' "$OUTPUT_DIR"
    printf '%s─────────────────────────────────────────%s\n' "$C_DIM" "$C_RST"
    echo
    printf 'Proceed? [Y/n] '
    local c
    IFS= read -r c || exit 0
    [[ "$c" =~ ^[nN] ]] && return 1
    return 0
}

# ---------- Progress bar ----------
show_progress() {
    local cur=$1 total=$2 start=$3
    local pct=0
    (( total > 0 )) && pct=$(( cur * 100 / total ))
    (( pct > 100 )) && pct=100

    local elapsed=$(( $(date +%s) - start ))
    local speed=0
    (( elapsed > 0 && cur > 0 )) && speed=$(( cur / elapsed ))

    local eta="--"
    if (( speed > 0 && total > 0 && cur < total )); then
        eta=$(format_time $(( (total - cur) / speed )))
    fi

    local width=28
    local filled=$(( pct * width / 100 ))
    local bar="" i
    for (( i=0; i<width; i++ )); do
        if (( i < filled )); then bar+="█"; else bar+="░"; fi
    done

    printf '\r  %s[%s]%s %3d%%  %s/%s frames  eta %-6s ' \
        "$C_CYN" "$bar" "$C_RST" "$pct" "$cur" "$total" "$eta"
}

# ---------- Compress ----------
compress_file() {
    local in="$1" out_dir="$2"

    local ext="mp4"
    (( KEEP_SUBTITLES == 1 )) && ext="mkv"

    local base out
    base="$(basename "$in")"
    out="$out_dir/${base%.*}.${ext}"
    if [[ -e "$out" ]]; then
        out="$out_dir/${base%.*}_compressed.${ext}"
        local n=1
        while [[ -e "$out" ]]; do
            out="$out_dir/${base%.*}_compressed_${n}.${ext}"
            n=$((n+1))
        done
    fi

    local scale_filter
    scale_filter="scale='min(${TARGET_W},iw)':'min(${TARGET_H},ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"

    # Cap audio at source bitrate (floor 64k)
    local target_audio="$AUDIO_BITRATE"
    if [[ "$SRC_ABITRATE" =~ ^[0-9]+$ && $SRC_ABITRATE -gt 0 ]]; then
        local src_a_kbps=$(( SRC_ABITRATE / 1000 ))
        local chosen_a_kbps="${AUDIO_BITRATE%k}"
        if (( src_a_kbps < 64 )); then
            target_audio="64k"
        elif (( src_a_kbps < chosen_a_kbps )); then
            target_audio="${src_a_kbps}k"
        fi
    fi

    # Build command
    local -a cmd=(ffmpeg -hide_banner -loglevel error -nostats -progress pipe:1 -y
        -i "$in"
    )

    # Stream mapping
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

    # Video
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

    # Audio (-strict -2 for FFmpeg 2.8's experimental AAC)
    if (( KEEP_SURROUND == 1 )); then
        cmd+=(-c:a aac -strict -2 -b:a "$target_audio")
    else
        cmd+=(-c:a aac -strict -2 -b:a "$target_audio" -ac 2)
    fi

    # Subtitles
    (( KEEP_SUBTITLES == 1 )) && cmd+=(-c:s copy)

    # MP4-only faststart
    [[ "$ext" == "mp4" ]] && cmd+=(-movflags +faststart)

    cmd+=("$out")

    echo
    log "In : $in"
    log "Out: $out"
    if [[ $USE_CRF -eq 1 ]]; then
        log "Settings: $RES_LABEL (max ${TARGET_W}×${TARGET_H}), CRF $CRF, audio ${target_audio}, preset $PRESET"
    else
        log "Settings: $RES_LABEL (max ${TARGET_W}×${TARGET_H}) @ ${VBITRATE}k, audio ${target_audio}, preset $PRESET"
    fi
    echo

    local total_frames="${SRC_FRAMES:-0}"
    [[ ! "$total_frames" =~ ^[0-9]+$ ]] && total_frames=0

    local start_ts
    start_ts=$(date +%s)
    local errfile fifo
    errfile=$(mktemp)
    fifo=$(mktemp -u)
    mkfifo "$fifo"

    "${cmd[@]}" 2>"$errfile" > "$fifo" &
    local ffpid=$!

    local cur_frame=0
    while IFS='=' read -r key value; do
        case "$key" in
            frame)
                cur_frame="${value//[^0-9]/}"
                [[ -z "$cur_frame" ]] && cur_frame=0
                if (( total_frames > 0 )); then
                    show_progress "$cur_frame" "$total_frames" "$start_ts"
                fi
                ;;
            progress)
                if [[ "$value" == "end" && $total_frames -gt 0 ]]; then
                    show_progress "$total_frames" "$total_frames" "$start_ts"
                fi
                ;;
        esac
    done < "$fifo"

    local exit_code=0
    wait "$ffpid" || exit_code=$?

    printf '\r%*s\r' 90 ''

    if (( exit_code != 0 )); then
        err "FFmpeg failed on: $in"
        [[ -s "$errfile" ]] && cat "$errfile" >&2
        rm -f "$fifo" "$errfile"
        return 1
    fi
    rm -f "$fifo" "$errfile"

    local end
    end=$(date +%s)
    local insz outsz ratio
    insz=$(stat -c%s "$in"  2>/dev/null || stat -f%z "$in")
    outsz=$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out")
    ratio=$(awk -v a="$insz" -v b="$outsz" 'BEGIN{ if(a>0) printf "%.1f", (1-b/a)*100; else print "0" }')

    local arrow="→"
    if (( outsz > insz )); then
        arrow="↑ GREW"
        warn "Output is LARGER than input — source was already heavily compressed."
    fi

    echo
    ok "Done in $((end-start_ts))s — ${ratio}% smaller ${arrow} ($(du -h "$in" | cut -f1) → $(du -h "$out" | cut -f1))"
}

# ---------- Main ----------
command -v ffmpeg >/dev/null 2>&1 || { err "ffmpeg not found in PATH."; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { HAVE_FFPROBE=0; warn "ffprobe not found — source info & frame progress limited."; }

banner
printf '  %sDetected %s CPU core(s)%s\n\n' "$C_DIM" "$CPU_CORES" "$C_RST"

while true; do
    # Reset per-file state
    KEEP_ALL_AUDIO=0
    KEEP_SURROUND=0
    KEEP_SUBTITLES=0
    AUDIO_BITRATE="128k"
    TUNE=""
    X264_PARAMS=""
    SPEED_PROFILE="balanced"
    THREADS=1
    DEFAULT_VBITRATE=0

    prompt_input_file
    probe_source "$INPUT_FILE"
    show_source_info
    prompt_resolution
    prompt_speed_profile
    prompt_bitrate
    prompt_audio_options
    prompt_subtitle_options
    prompt_output_dir

    if ! confirm_summary; then
        warn "Cancelled."
        echo
    else
        compress_file "$INPUT_FILE" "$OUTPUT_DIR" || true
    fi

    echo
    printf 'Compress another video? [y/N] '
    IFS= read -r again || break
    case "$again" in
        [yY]*) echo; echo ;;
        *)     break ;;
    esac
done

echo
ok "All done."
