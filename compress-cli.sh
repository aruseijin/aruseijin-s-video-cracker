#!/usr/bin/env bash
#
# compress-cli.sh — Interactive video compressor using FFmpeg
#
set -uo pipefail

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
NEEDS_STRICT=0

CPU_CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
CPU_CORES="${CPU_CORES//[^0-9]/}"
[[ -z "$CPU_CORES" || "$CPU_CORES" -eq 0 ]] && CPU_CORES=1
(( CPU_CORES > 16 )) && CPU_CORES=16

SPEED_PROFILE="balanced"
TUNE=""
X264_PARAMS=""
THREADS=1

KEEP_ALL_AUDIO=0
KEEP_SURROUND=0
KEEP_SUBTITLES=0

SRC_W=""; SRC_H=""; SRC_VBITRATE=""; SRC_ABITRATE=""
SRC_DURATION=""; SRC_FRAMES=""; SRC_SIZE=0
SRC_HAS_MULTI_AUDIO=0
SRC_AUDIO_CHANNELS=""
SRC_SUB_COUNT=0

FFMPEG_VERSION_STR=""

# ---------- Helpers ----------
expand_path() {
    local p="$1"
    p="${p/#\~/$HOME}"
    printf '%s' "$p"
}

banner() {
    local v="${FFMPEG_VERSION_STR:-unknown}"
    if [[ "$v" =~ ffmpeg\ version\ ([^ ]+) ]]; then
        v="${BASH_REMATCH[1]}"
    fi
    local probe_status="available"
    [[ $HAVE_FFPROBE -eq 0 ]] && probe_status="MISSING"

    printf '\n'
    printf '%s%s' "$C_CYN" "$C_BLD"
    cat <<'EOF'
  ╔══════════════════════════════════════════════════╗
  ║                                                  ║
  ║              A R U S E I J I N ' S               ║
  ║         V I D E O   C O M P R E S S O R          ║
  ║           FFmpeg-powered batch frontend          ║
  ║                                                  ║
  ╚══════════════════════════════════════════════════╝
EOF
    printf '%s\n' "$C_RST"
    printf '  %sffmpeg %s  ·  %s thread(s)  ·  ffprobe %s%s\n' \
        "$C_DIM" "$v" "$CPU_CORES" "$probe_status" "$C_RST"
    printf '\n'
}

format_time() {
    local s=$1
    if   [[ $s -lt 60   ]]; then printf '%ds' "$s"
    elif [[ $s -lt 3600 ]]; then printf '%dm%02ds' $((s/60)) $((s%60))
    else                        printf '%dh%02dm' $((s/3600)) $(((s%3600)/60))
    fi
}

# Translate (exit_code, ffmpeg stderr) into a friendly explanation.
diagnose_ffmpeg_error() {
    local exit_code="$1"
    local stderr_text="$2"
    local lower
    lower=$(printf '%s' "$stderr_text" | tr '[:upper:]' '[:lower:]')

    case "$exit_code" in
        130) echo "Encoding was interrupted."; return ;;
        132) echo "The encoder tried to run an instruction this CPU doesn't understand (SIGILL). The ffmpeg binary was probably built for a newer CPU than this one. A portable static build — the johnvansickle.com one — usually fixes this."; return ;;
        134) echo "The encoder aborted unexpectedly. That's a bug in ffmpeg or one of its libraries."; return ;;
        137) echo "The encoder was killed — almost always out of RAM. Try a smaller resolution, or close other programs."; return ;;
        139) echo "The encoder crashed with a segmentation fault. Usually a bug in this ffmpeg build, or a decoder choking on this particular file."; return ;;
        141) echo "Encoding was cancelled."; return ;;
        143) echo "Encoding was stopped."; return ;;
    esac

    if [[ "$lower" == *"moov atom not found"* ]]; then
        echo "This file is missing its MP4 'moov' atom — the header that tells players how to read it. That happens when a download or copy gets interrupted. Try re-downloading the file."
        return
    fi
    if [[ "$lower" == *"invalid data found when processing input"* ]] || \
       [[ "$lower" == *"could not find codec parameters"* ]]; then
        echo "ffmpeg couldn't make sense of this file. It's very likely corrupted or only partially downloaded."
        return
    fi
    if [[ "$lower" == *"invalid nal unit"* ]] || [[ "$lower" == *"header missing"* ]] || \
       [[ "$lower" == *"error while decoding"* ]] || [[ "$lower" == *"truncated"* ]]; then
        echo "The video stream is damaged somewhere partway through. The file is probably corrupt, and re-encoding can't fix that — you'd need a clean copy of the source."
        return
    fi
    if [[ "$lower" == *"no space left on device"* ]]; then
        echo "Ran out of space on the output drive. Free some up and try again."
        return
    fi
    if [[ "$lower" == *"permission denied"* ]]; then
        echo "Couldn't write to the output folder — permission denied. Try a different folder, or check its permissions."
        return
    fi
    if [[ "$lower" == *"cannot allocate memory"* ]] || [[ "$lower" == *"out of memory"* ]]; then
        echo "ffmpeg ran out of memory. Close other programs, or try a smaller resolution."
        return
    fi
    if [[ "$lower" == *"unknown decoder"* ]] || [[ "$lower" == *"decoder (codec"* ]] || \
       [[ "$lower" == *"decoder not found"* ]]; then
        echo "This copy of ffmpeg doesn't have the decoder needed for this file's codec. A fuller build — the static one from johnvansickle.com — should handle it."
        return
    fi
    if [[ "$lower" == *"could not write header"* ]] || [[ "$lower" == *"conversion failed"* ]]; then
        echo "ffmpeg couldn't finish writing the output. Usually a corrupt source file or a full disk."
        return
    fi
    if [[ "$lower" == *"invalid argument"* ]]; then
        echo "ffmpeg rejected one of the settings. Try a different resolution, bitrate, or speed profile."
        return
    fi
    if [[ -z "$stderr_text" ]]; then
        echo "ffmpeg exited without saying why. Usually that means it was killed by a signal rather than failing on its own."
        return
    fi

    echo "ffmpeg hit an unexpected error. The full output is below if you want to dig into it."
}

# ---------- Source probing ----------
probe_source() {
    local f="$1"
    SRC_W=""; SRC_H=""; SRC_VBITRATE=""; SRC_ABITRATE=""
    SRC_DURATION=""; SRC_FRAMES=""; SRC_SIZE=0
    SRC_HAS_MULTI_AUDIO=0; SRC_AUDIO_CHANNELS=""; SRC_SUB_COUNT=0

    [[ $HAVE_FFPROBE -eq 0 ]] && return 0

    local dims
    dims=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
        -of csv=s=x:p=0 "$f" 2>/dev/null) || dims=""
    if [[ "$dims" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        SRC_W="${BASH_REMATCH[1]}"; SRC_H="${BASH_REMATCH[2]}"
    fi

    SRC_DURATION=$(ffprobe -v error -show_entries format=duration \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null) || SRC_DURATION=""
    [[ ! "$SRC_DURATION" =~ ^[0-9.]+$ ]] && SRC_DURATION=""

    SRC_VBITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null) || SRC_VBITRATE=""
    [[ ! "$SRC_VBITRATE" =~ ^[0-9]+$ ]] && SRC_VBITRATE=""

    SRC_ABITRATE=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null) || SRC_ABITRATE=""
    [[ ! "$SRC_ABITRATE" =~ ^[0-9]+$ ]] && SRC_ABITRATE=""

    SRC_FRAMES=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null) || SRC_FRAMES=""
    [[ ! "$SRC_FRAMES" =~ ^[0-9]+$ ]] && SRC_FRAMES=""

    local audio_count
    audio_count=$(ffprobe -v error -select_streams a -show_entries stream=index \
        -of csv=p=0 "$f" 2>/dev/null | grep -c .) || audio_count=0
    [[ ! "$audio_count" =~ ^[0-9]+$ ]] && audio_count=0
    (( audio_count > 1 )) && SRC_HAS_MULTI_AUDIO=1

    SRC_AUDIO_CHANNELS=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null) || SRC_AUDIO_CHANNELS=""
    [[ ! "$SRC_AUDIO_CHANNELS" =~ ^[0-9]+$ ]] && SRC_AUDIO_CHANNELS=""

    local sub_count
    sub_count=$(ffprobe -v error -select_streams s -show_entries stream=index \
        -of csv=p=0 "$f" 2>/dev/null | grep -c .) || sub_count=0
    [[ ! "$sub_count" =~ ^[0-9]+$ ]] && sub_count=0
    SRC_SUB_COUNT=$sub_count

    SRC_SIZE=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
    [[ ! "$SRC_SIZE" =~ ^[0-9]+$ ]] && SRC_SIZE=0

    if [[ -z "$SRC_VBITRATE" && -n "$SRC_DURATION" && $SRC_SIZE -gt 0 ]]; then
        local a="${SRC_ABITRATE:-0}"
        [[ ! "$a" =~ ^[0-9]+$ ]] && a=0
        SRC_VBITRATE=$(awk -v s="$SRC_SIZE" -v d="$SRC_DURATION" -v a="$a" \
            'BEGIN{ if(d<=0){print 0; exit}; v=(s*8/d)-a; if(v<0) v=0; printf "%d", v }')
        [[ ! "$SRC_VBITRATE" =~ ^[0-9]+$ ]] && SRC_VBITRATE=""
    fi

    if [[ -z "$SRC_FRAMES" && -n "$SRC_DURATION" ]]; then
        local fps_str
        fps_str=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
            -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null) || fps_str=""
        local n="" d=""
        if [[ "$fps_str" =~ ^([0-9]+)/([0-9]+)$ ]]; then
            n="${BASH_REMATCH[1]}"; d="${BASH_REMATCH[2]}"
        elif [[ "$fps_str" =~ ^([0-9]+)$ ]]; then
            n="$fps_str"; d=1
        fi
        if [[ -n "$n" && -n "$d" && "$d" != "0" ]]; then
            SRC_FRAMES=$(awk -v dur="$SRC_DURATION" -v n="$n" -v d="$d" \
                'BEGIN{ if(d<=0){print 0; exit}; printf "%d", dur*n/d }')
            [[ ! "$SRC_FRAMES" =~ ^[0-9]+$ ]] && SRC_FRAMES=""
        fi
    fi

    return 0
}

detect_ffmpeg() {
    local v
    v=$(ffmpeg -version 2>/dev/null | head -n1 || echo "")
    FFMPEG_VERSION_STR="$v"
    if [[ "$v" =~ ffmpeg\ version\ ([0-9]+) ]]; then
        (( BASH_REMATCH[1] < 4 )) && NEEDS_STRICT=1
    else
        NEEDS_STRICT=1
    fi
}

show_source_info() {
    [[ $HAVE_FFPROBE -eq 0 ]] && return 0
    printf '%s  Source info:%s\n' "$C_DIM" "$C_RST"
    [[ -n "$SRC_W" ]] && printf '    Resolution: %s\n' "${SRC_W}×${SRC_H}"
    [[ -n "$SRC_VBITRATE" && $SRC_VBITRATE -gt 0 ]] && \
        printf '    Video:      ~%s kbps\n' $(( SRC_VBITRATE / 1000 ))
    if [[ -n "$SRC_ABITRATE" && $SRC_ABITRATE -gt 0 ]]; then
        printf '    Audio:      ~%s kbps' $(( SRC_ABITRATE / 1000 ))
        [[ -n "$SRC_AUDIO_CHANNELS" ]] && printf ' (%s ch)' "$SRC_AUDIO_CHANNELS"
        printf '\n'
    fi
    (( SRC_HAS_MULTI_AUDIO == 1 )) && printf '    Audio tracks: multiple\n'
    (( SRC_SUB_COUNT > 0 )) && printf '    Subtitles:    %s stream(s)\n' "$SRC_SUB_COUNT"
    [[ -n "$SRC_DURATION" ]] && printf '    Duration:   %.1fs\n' "$SRC_DURATION"
    [[ -n "$SRC_FRAMES" && $SRC_FRAMES -gt 0 ]] && printf '    Frames:     %s\n' "$SRC_FRAMES"
    (( SRC_SIZE > 0 )) && printf '    Size:       %s\n' "$(du -h "$INPUT_FILE" | cut -f1)"
    echo
    return 0
}

# ---------- Error display ----------
print_error_box() {
    local friendly="$1"
    local file="$2"
    local details="$3"
    local exit_code="${4:-?}"

    echo
    printf '%s╭──────────────────────────────────────────────╮%s\n' "$C_RED" "$C_RST"
    printf '%s│%s  %s:(  Encoding failed%s                 %s│%s\n' \
        "$C_RED" "$C_RST" "$C_BLD" "$C_RST" "$C_RED" "$C_RST"
    printf '%s╰──────────────────────────────────────────────╯%s\n' "$C_RED" "$C_RST"
    echo
    printf '  %sFile:%s   %s\n' "$C_BLD" "$C_RST" "$file"
    printf '  %sCode:%s   %s\n' "$C_BLD" "$C_RST" "$exit_code"
    echo
    printf '  %s\n' "$friendly"
    echo

    if [[ -n "$details" ]]; then
        printf '  %s┌─ what ffmpeg actually said ─────────────────%s\n' "$C_DIM" "$C_RST"
        while IFS= read -r line; do
            printf '  %s│%s %s\n' "$C_DIM" "$C_RST" "${line:0:72}"
        done <<< "$details"
        printf '  %s└─────────────────────────────────────────────┘%s\n' "$C_DIM" "$C_RST"
        echo
    fi

    printf '  %sNo output file was saved.%s\n' "$C_DIM" "$C_RST"
    echo
}

# ---------- Prompts ----------
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

prompt_speed_profile() {
    echo
    printf '%sEncoding speed profile%s\n' "$C_BLD" "$C_RST"
    printf '  1) %sFast%s       netbook-friendly (~5–10× faster, larger files)\n' "$C_GRN" "$C_RST"
    printf '  2) %sBalanced%s   good compromise\n' "$C_GRN" "$C_RST"
    printf '  3) %sQuality%s    smallest files, slowest\n' "$C_GRN" "$C_RST"

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
    return 0
}

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

prompt_bitrate() {
    local src_kbps=0
    if [[ -n "$SRC_VBITRATE" && $SRC_VBITRATE -gt 0 ]]; then
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
        VBITRATE="$DEFAULT_VBITRATE"; USE_CRF=0
    elif [[ "$input" == "auto" || "$input" == "0" ]]; then
        USE_CRF=1; VBITRATE=0
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        VBITRATE="$input"; USE_CRF=0
        if [[ $src_kbps -gt 0 && $VBITRATE -ge $src_kbps ]]; then
            warn "Target ${VBITRATE}k ≥ source ${src_kbps}k — output may be BIGGER."
            printf 'Continue anyway? [y/N] '
            local c
            IFS= read -r c || exit 0
            if [[ ! "$c" =~ ^[yY] ]]; then
                prompt_bitrate
                return 0
            fi
        fi
    else
        err "Enter a number, 'auto', or hit Enter for default."
        prompt_bitrate
        return 0
    fi
    return 0
}

prompt_audio_options() {
    echo
    if (( SRC_HAS_MULTI_AUDIO == 1 )); then
        printf '%sSource has multiple audio tracks.%s Keep all of them? [y/N] ' \
            "$C_YEL" "$C_RST"
        local c
        IFS= read -r c || exit 0
        [[ "$c" =~ ^[yY] ]] && KEEP_ALL_AUDIO=1 || KEEP_ALL_AUDIO=0
    fi

    if [[ -n "$SRC_AUDIO_CHANNELS" && $SRC_AUDIO_CHANNELS -gt 2 ]]; then
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
    return 0
}

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
    return 0
}

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
        return 0
    fi
    if ! mkdir -p "$out" 2>/dev/null; then
        err "Could not create directory: $out"
        prompt_output_dir
        return 0
    fi
    OUTPUT_DIR="$out"
    return 0
}

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
    printf '  Codec:      %s (preset %s, %s thread(s))\n' "$CODEC" "$PRESET" "$THREADS"
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
    return 0
}

# ---------- Compress ----------
COMPRESS_ERROR_MSG=""
COMPRESS_ERROR_DETAILS=""
COMPRESS_ERROR_CODE=""
COMPRESS_OUTPUT_PATH=""

compress_file() {
    local in="$1" out_dir="$2"
    COMPRESS_ERROR_MSG=""
    COMPRESS_ERROR_DETAILS=""
    COMPRESS_ERROR_CODE=""
    COMPRESS_OUTPUT_PATH=""

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
    COMPRESS_OUTPUT_PATH="$out"

    local scale_filter
    scale_filter="scale='min(${TARGET_W},iw)':'min(${TARGET_H},ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"

    local target_audio="$AUDIO_BITRATE"
    if [[ -n "$SRC_ABITRATE" && $SRC_ABITRATE -gt 0 ]]; then
        local src_a_kbps=$(( SRC_ABITRATE / 1000 ))
        local chosen_a_kbps="${AUDIO_BITRATE%k}"
        [[ ! "$chosen_a_kbps" =~ ^[0-9]+$ ]] && chosen_a_kbps=128
        if (( src_a_kbps < 64 )); then
            target_audio="64k"
        elif (( src_a_kbps < chosen_a_kbps )); then
            target_audio="${src_a_kbps}k"
        fi
    fi

    local -a cmd=(ffmpeg -hide_banner -loglevel error -nostats -progress pipe:1 -y -i "$in")

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

    cmd+=(-vf "$scale_filter" -c:v "$CODEC" -preset "$PRESET" -threads "$THREADS")
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

    local -a audio_opts=(-c:a aac)
    (( NEEDS_STRICT == 1 )) && audio_opts+=(-strict -2)
    audio_opts+=(-b:a "$target_audio")
    (( KEEP_SURROUND == 0 )) && audio_opts+=(-ac 2)
    cmd+=("${audio_opts[@]}")

    (( KEEP_SUBTITLES == 1 )) && cmd+=(-c:s copy)
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
    [[ "${DEBUG:-0}" == "1" ]] && printf '%s  FFmpeg: %q %s%s\n' "$C_DIM" "${cmd[0]}" "${cmd[*]:1}" "$C_RST"
    echo

    local total_frames="${SRC_FRAMES:-0}"
    [[ ! "$total_frames" =~ ^[0-9]+$ ]] && total_frames=0

    local start_ts; start_ts=$(date +%s)
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

    # ---------- FAILURE ----------
    if (( exit_code != 0 )); then
        local raw_err=""
        [[ -s "$errfile" ]] && raw_err="$(tail -c 1500 "$errfile")"
        rm -f "$fifo" "$errfile"
        if [[ -e "$out" ]]; then
            rm -f "$out" && log "Removed partial output: $out"
        fi

        COMPRESS_ERROR_CODE="$exit_code"
        COMPRESS_ERROR_DETAILS="$raw_err"
        COMPRESS_ERROR_MSG="$(diagnose_ffmpeg_error "$exit_code" "$raw_err")"
        return 1
    fi
    rm -f "$fifo" "$errfile"

    if [[ ! -s "$out" ]]; then
        COMPRESS_ERROR_CODE="0"
        COMPRESS_ERROR_DETAILS=""
        COMPRESS_ERROR_MSG="ffmpeg said it finished, but the output file is missing or empty. That's a strange one."
        return 1
    fi

    # ---------- SUCCESS ----------
    local end; end=$(date +%s)
    local insz outsz ratio
    insz=$(stat -c%s "$in" 2>/dev/null || stat -f%z "$in")
    outsz=$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out")
    ratio=$(awk -v a="$insz" -v b="$outsz" 'BEGIN{ if(a>0) printf "%.1f", (1-b/a)*100; else print "0" }')

    local arrow="→"
    if (( outsz > insz )); then
        arrow="↑ GREW"
        warn "Output is LARGER than input — source was already heavily compressed."
    fi

    echo
    ok "Done in $((end-start_ts))s — ${ratio}% smaller ${arrow} ($(du -h "$in" | cut -f1) → $(du -h "$out" | cut -f1))"
    return 0
}

# ---------- Main ----------
command -v ffmpeg >/dev/null 2>&1 || { err "ffmpeg not found in PATH."; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { HAVE_FFPROBE=0; warn "ffprobe not found — source info & frame progress limited."; }
detect_ffmpeg

banner

while true; do
    # --- pick a file and probe it once ---
    prompt_input_file
    probe_source "$INPUT_FILE"
    show_source_info

    # --- retry loop for THIS file ---
    while true; do
        # Reset per-attempt state
        KEEP_ALL_AUDIO=0
        KEEP_SURROUND=0
        KEEP_SUBTITLES=0
        AUDIO_BITRATE="128k"
        TUNE=""
        X264_PARAMS=""
        SPEED_PROFILE="balanced"
        THREADS=1
        DEFAULT_VBITRATE=0

        prompt_resolution
        prompt_speed_profile
        prompt_bitrate
        prompt_audio_options
        prompt_subtitle_options
        prompt_output_dir

        if ! confirm_summary; then
            warn "Cancelled."
            echo
            break
        fi

        if compress_file "$INPUT_FILE" "$OUTPUT_DIR"; then
            break
        fi

        # ---------- ERROR PATH ----------
        print_error_box "$COMPRESS_ERROR_MSG" "$INPUT_FILE" "$COMPRESS_ERROR_DETAILS" "$COMPRESS_ERROR_CODE"
        printf '  %sTry again with different settings? [y/N]%s ' "$C_BLD" "$C_RST"
        retry=""
        IFS= read -r retry || exit 0
        if [[ ! "$retry" =~ ^[yY] ]]; then
            echo
            break
        fi
        echo
        printf '%s%sRetrying %s…%s\n' "$C_BLD" "$C_YEL" "$(basename "$INPUT_FILE")" "$C_RST"
    done

    echo
    printf 'Want to do another one? [y/N] '
    IFS= read -r again || break
    case "$again" in
        [yY]*) echo; echo ;;
        *)     break ;;
    esac
done

echo
ok "All done."
