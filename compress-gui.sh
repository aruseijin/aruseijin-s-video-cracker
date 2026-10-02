#!/usr/bin/env bash
#
# compress-gui.sh — Zenity GUI frontend for FFmpeg video compression
#
set -uo pipefail
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
    zenity --error --icon-name="dialog-error" --title="Can't find ffmpeg :(" --width=360 \
        --text="ffmpeg wasn't found on this system.\n\nInstall it and try again — your package manager should have it."
    exit 1
fi

HAVE_FFPROBE=1
command -v ffprobe >/dev/null 2>&1 || HAVE_FFPROBE=0
NEEDS_STRICT=0

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

CPU_CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
CPU_CORES="${CPU_CORES//[^0-9]/}"
[[ -z "$CPU_CORES" || "$CPU_CORES" -eq 0 ]] && CPU_CORES=1
(( CPU_CORES > 16 )) && CPU_CORES=16

TITLE="Aruseijin's Video Compressor"

# ---------- Helpers ----------
xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

format_time() {
    local s=$1
    if   [[ $s -lt 60   ]]; then printf '%ds' "$s"
    elif [[ $s -lt 3600 ]]; then printf '%dm %ds' $((s/60)) $((s%60))
    else                        printf '%dh %dm' $((s/3600)) $(((s%3600)/60))
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

detect_ffmpeg() {
    local v
    v=$(ffmpeg -version 2>/dev/null | head -n1 || echo "")
    if [[ "$v" =~ ffmpeg\ version\ ([0-9]+) ]]; then
        (( BASH_REMATCH[1] < 4 )) && NEEDS_STRICT=1
    else
        NEEDS_STRICT=1
    fi
}

# Translate (exit_code, ffmpeg stderr) into a friendly explanation.
diagnose_ffmpeg_error() {
    local exit_code="$1"
    local stderr_text="$2"
    local lower
    lower=$(printf '%s' "$stderr_text" | tr '[:upper:]' '[:lower:]')

    # --- Signal deaths: exit code is more specific than stderr ---
    case "$exit_code" in
        130) echo "Encoding was interrupted."; return ;;
        132)
            echo "The encoder tried to run an instruction this CPU doesn't understand (SIGILL). The ffmpeg binary on this machine was probably built for a newer CPU than it's actually running on. A portable static build — the johnvansickle.com one — usually fixes this."
            return ;;
        134) echo "The encoder aborted unexpectedly. That's a bug in ffmpeg or in one of its libraries, not something you can fix from here."; return ;;
        137) echo "The encoder was killed — almost always because the machine ran out of RAM. Try a smaller resolution, or close some other programs first."; return ;;
        139) echo "The encoder crashed with a segmentation fault. Usually a bug in this ffmpeg build, or a decoder choking on this particular file."; return ;;
        141) echo "Encoding was cancelled."; return ;;
        143) echo "Encoding was stopped."; return ;;
    esac

    # --- File looks broken/incomplete ---
    if [[ "$lower" == *"moov atom not found"* ]]; then
        echo "This file is missing its MP4 'moov' atom — the little header that tells players how to read it. That happens when a download or copy gets interrupted partway through. Try re-downloading the file."
        return
    fi

    if [[ "$lower" == *"invalid data found when processing input"* ]] || \
       [[ "$lower" == *"could not find codec parameters"* ]]; then
        echo "ffmpeg couldn't make sense of this file. It's very likely corrupted or only partially downloaded."
        return
    fi

    if [[ "$lower" == *"invalid nal unit"* ]] || [[ "$lower" == *"header missing"* ]] || \
       [[ "$lower" == *"error while decoding"* ]] || [[ "$lower" == *"truncated"* ]]; then
        echo "The video stream is damaged somewhere partway through. The file is probably corrupt, and re-encoding can't repair that — you'd need a clean copy of the source."
        return
    fi

    # --- Environment problems ---
    if [[ "$lower" == *"no space left on device"* ]]; then
        echo "Ran out of space on the output drive. Free some up and try again."
        return
    fi

    if [[ "$lower" == *"permission denied"* ]]; then
        echo "Couldn't write to the output folder — permission denied. Try a different folder, or check the folder's permissions."
        return
    fi

    if [[ "$lower" == *"cannot allocate memory"* ]] || [[ "$lower" == *"out of memory"* ]]; then
        echo "ffmpeg ran out of memory. Close some other programs, or try a smaller resolution."
        return
    fi

    # --- Codec issues ---
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
        echo "ffmpeg exited without saying why. That usually means it was killed by a signal rather than failing on its own."
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

    local ac
    ac=$(ffprobe -v error -select_streams a -show_entries stream=index \
        -of csv=p=0 "$f" 2>/dev/null | grep -c .) || ac=0
    [[ ! "$ac" =~ ^[0-9]+$ ]] && ac=0
    (( ac > 1 )) && SRC_HAS_MULTI_AUDIO=1

    SRC_AUDIO_CHANNELS=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels \
        -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null) || SRC_AUDIO_CHANNELS=""
    [[ ! "$SRC_AUDIO_CHANNELS" =~ ^[0-9]+$ ]] && SRC_AUDIO_CHANNELS=""

    local sc
    sc=$(ffprobe -v error -select_streams s -show_entries stream=index \
        -of csv=p=0 "$f" 2>/dev/null | grep -c .) || sc=0
    [[ ! "$sc" =~ ^[0-9]+$ ]] && sc=0
    SRC_SUB_COUNT=$sc

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

# ---------- Source info (markup OK via --info) ----------
source_info_text() {
    local t=""
    t+="<b>Source file</b>\n"
    t+="<small>$(xml_escape "$(basename "$INPUT_FILE")")</small>\n\n"
    [[ -n "$SRC_W" ]] && t+="<b>Resolution</b>    ${SRC_W}×${SRC_H}\n"
    if [[ -n "$SRC_VBITRATE" && $SRC_VBITRATE -gt 0 ]]; then
        t+="<b>Video</b>         ~$(( SRC_VBITRATE / 1000 )) kbps\n"
    fi
    if [[ -n "$SRC_ABITRATE" && $SRC_ABITRATE -gt 0 ]]; then
        t+="<b>Audio</b>         ~$(( SRC_ABITRATE / 1000 )) kbps"
        [[ -n "$SRC_AUDIO_CHANNELS" ]] && t+=" ($SRC_AUDIO_CHANNELS ch)"
        t+="\n"
    fi
    (( SRC_HAS_MULTI_AUDIO == 1 )) && t+="<b>Audio tracks</b>  multiple\n"
    (( SRC_SUB_COUNT > 0 )) && t+="<b>Subtitles</b>     $SRC_SUB_COUNT stream(s)\n"
    [[ -n "$SRC_DURATION" ]] && t+="<b>Duration</b>      $(printf '%.1f' "$SRC_DURATION")s\n"
    [[ -n "$SRC_FRAMES" && $SRC_FRAMES -gt 0 ]] && t+="<b>Frames</b>        $SRC_FRAMES\n"
    (( SRC_SIZE > 0 )) && t+="<b>Size</b>          $(human_size "$SRC_SIZE")\n"
    printf '%b' "$t"
}

# ---------- Pick input file ----------
pick_file() {
    local f
    f=$(zenity --file-selection \
        --title="$TITLE — choose input video" \
        --icon-name="video-x-generic" \
        --file-filter="Video files | *.mp4 *.mkv *.mov *.avi *.webm *.flv *.wmv *.m4v *.mpg *.mpeg *.ts *.m2ts *.3gp *.ogv" \
        --file-filter="All files | *" 2>/dev/null) || return 1
    [[ -z "$f" ]] && return 1
    INPUT_FILE="$f"
    return 0
}

# ---------- Single settings form ----------
# NOTE: --forms does NOT support Pango markup. Plain text only.
pick_settings() {
    TUNE=""; X264_PARAMS=""

    local src_kbps=0
    if [[ -n "$SRC_VBITRATE" && $SRC_VBITRATE -gt 0 ]]; then
        src_kbps=$(( SRC_VBITRATE / 1000 ))
    fi

    local -a args=(
        --title="$TITLE — encoding settings"
        --text="Configure the encoding, then click OK."
        --separator="|"
        --add-combo="Resolution" --combo-values="720p (1280x720)|480p (854x480)|360p (640x360)|Custom"
        --add-entry="Custom width (only if Custom)"
        --add-entry="Custom height (only if Custom)"
        --add-combo="Speed profile" --combo-values="Fast (recommended for slow CPUs)|Balanced|Quality"
        --add-entry="Bitrate kbps (blank = default, auto = CRF)"
    )

    local idx_res=0 idx_cw=1 idx_ch=2 idx_spd=3 idx_br=4
    local idx_ka=-1 idx_ks=-1 idx_kst=-1
    local next=5

    if (( SRC_HAS_MULTI_AUDIO == 1 )); then
        args+=(--add-combo="Keep all audio tracks" --combo-values="No|Yes")
        idx_ka=$next; next=$((next+1))
    fi
    if [[ -n "$SRC_AUDIO_CHANNELS" && $SRC_AUDIO_CHANNELS -gt 2 ]]; then
        args+=(--add-combo="Keep surround audio" --combo-values="No (downmix to stereo)|Yes")
        idx_ks=$next; next=$((next+1))
    fi
    if (( SRC_SUB_COUNT > 0 )); then
        args+=(--add-combo="Keep subtitles (forces .mkv)" --combo-values="No|Yes")
        idx_kst=$next; next=$((next+1))
    fi

    local out
    out=$(zenity --forms "${args[@]}" 2>/dev/null) || return 1
    [[ -z "$out" ]] && return 1

    local -a f
    IFS='|' read -ra f <<< "$out"

    # --- Resolution ---
    case "${f[$idx_res]}" in
        "720p"*) TARGET_W=1280; TARGET_H=720; RES_LABEL="720p"; DEFAULT_VBITRATE=2500; CRF=24 ;;
        "480p"*) TARGET_W=854;  TARGET_H=480; RES_LABEL="480p"; DEFAULT_VBITRATE=1000; CRF=26 ;;
        "360p"*) TARGET_W=640;  TARGET_H=360; RES_LABEL="360p"; DEFAULT_VBITRATE=600;  CRF=28 ;;
        "Custom")
            local w="${f[$idx_cw]}" h="${f[$idx_ch]}"
            if [[ ! "$w" =~ ^[0-9]+$ || ! "$h" =~ ^[0-9]+$ ]]; then
                zenity --error --icon-name="dialog-error" --title="$TITLE" --width=420 \
                    --text="Those dimensions don't look right.\n\nWidth and height need to be plain numbers, like 1024 and 576."
                return 1
            fi
            TARGET_W="$w"; TARGET_H="$h"; RES_LABEL="${h}p"
            DEFAULT_VBITRATE=$(( (w*h)/350 ))
            (( DEFAULT_VBITRATE < 300 )) && DEFAULT_VBITRATE=300
            CRF=26
            ;;
        *) return 1 ;;
    esac

    if (( src_kbps > 0 )); then
        local cap=$(( src_kbps * 3 / 4 ))
        (( cap < DEFAULT_VBITRATE )) && DEFAULT_VBITRATE=$cap
        (( DEFAULT_VBITRATE < 100 )) && DEFAULT_VBITRATE=100
    fi

    # --- Speed ---
    case "${f[$idx_spd]}" in
        "Fast"*)
            PRESET="ultrafast"; TUNE="fastdecode"
            X264_PARAMS="rc-lookahead=10:ref=1:bframes=0:me=dia:subme=1:trellis=0:8x8dct=0:mixed-refs=0:weightp=0:sliced-threads=1"
            ;;
        "Balanced")
            PRESET="superfast"; TUNE=""
            X264_PARAMS="rc-lookahead=20:ref=2:sliced-threads=1"
            ;;
        "Quality")
            PRESET="veryfast"; TUNE=""
            X264_PARAMS=""
            ;;
        *) return 1 ;;
    esac
    THREADS="$CPU_CORES"
    (( THREADS < 1 )) && THREADS=1

    # --- Bitrate ---
    local br="${f[$idx_br]}"
    if [[ -z "$br" ]]; then
        VBITRATE="$DEFAULT_VBITRATE"; USE_CRF=0
    elif [[ "$br" == "auto" || "$br" == "0" ]]; then
        USE_CRF=1; VBITRATE=0
    elif [[ "$br" =~ ^[0-9]+$ ]]; then
        VBITRATE="$br"; USE_CRF=0
        if (( src_kbps > 0 && VBITRATE >= src_kbps )); then
            if ! zenity --question --icon-name="dialog-warning" --title="$TITLE" --width=480 \
                --text="<b>Heads up — the output might be bigger</b>\n\nYou asked for ${VBITRATE} kbps, but the source is only about ${src_kbps} kbps.\n\nRe-encoding at a higher bitrate will inflate the file.\n\nContinue anyway?"; then
                return 1
            fi
        fi
    else
        zenity --error --icon-name="dialog-error" --title="$TITLE" --width=420 \
            --text="Hmm, that's not quite right.\n\nEnter a number, the word auto, or just leave it blank."
        return 1
    fi

    # --- Optional audio/subs ---
    (( idx_ka >= 0 )) && [[ "${f[$idx_ka]}" == "Yes" ]] && KEEP_ALL_AUDIO=1
    if (( idx_ks >= 0 )) && [[ "${f[$idx_ks]}" == "Yes" ]]; then
        KEEP_SURROUND=1
        AUDIO_BITRATE="384k"
    fi
    (( idx_kst >= 0 )) && [[ "${f[$idx_kst]}" == "Yes" ]] && KEEP_SUBTITLES=1

    return 0
}

# ---------- Pick output directory ----------
pick_output() {
    local d
    d=$(zenity --file-selection --directory \
        --icon-name="folder-open" \
        --title="$TITLE — choose output folder" 2>/dev/null) || return 1
    [[ -z "$d" ]] && return 1
    if ! mkdir -p "$d" 2>/dev/null; then
        zenity --error --icon-name="dialog-error" --title="$TITLE" --width=360 \
            --text="Couldn't make that folder:\n\n$(xml_escape "$d")"
        return 1
    fi
    OUTPUT_DIR="$d"
    return 0
}

# ---------- Confirm (markup OK via --question) ----------
confirm() {
    local ext="mp4"; (( KEEP_SUBTITLES == 1 )) && ext="mkv"
    local br
    if (( USE_CRF == 1 )); then br="auto (CRF $CRF)"; else br="${VBITRATE} kbps"; fi
    local audio_desc="stereo"
    (( KEEP_SURROUND == 1 )) && audio_desc="surround (${AUDIO_BITRATE})"
    local audio_trk="main track only"; (( KEEP_ALL_AUDIO == 1 )) && audio_trk="all tracks"
    local sub_desc="dropped"; (( KEEP_SUBTITLES == 1 )) && sub_desc="${SRC_SUB_COUNT} stream(s) kept"

    local text
    text="<b>Here's the plan:</b>\n\n"
    text+="<b>File</b>         $(xml_escape "$(basename "$INPUT_FILE")")\n\n"
    text+="<b>Resolution</b>   $RES_LABEL (max ${TARGET_W}×${TARGET_H})\n"
    text+="<b>Bitrate</b>      $br\n"
    text+="<b>Speed</b>        $PRESET ($THREADS thread(s))\n"
    text+="<b>Audio</b>        $audio_desc, $audio_trk\n"
    text+="<b>Subtitles</b>    $sub_desc\n"
    text+="<b>Container</b>    .$ext\n\n"
    text+="<b>Output folder</b>\n<small>$(xml_escape "$OUTPUT_DIR")</small>"

    zenity --question --icon-name="dialog-question" --title="$TITLE — confirm" \
        --width=520 --text="$text" \
        --ok-label="Encode" --cancel-label="Cancel"
}

# ---------- Compress with progress ----------
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

    local target_audio="$AUDIO_BITRATE"
    if [[ -n "$SRC_ABITRATE" && $SRC_ABITRATE -gt 0 ]]; then
        local src_a_kbps=$(( SRC_ABITRATE / 1000 ))
        local chosen_a_kbps="${AUDIO_BITRATE%k}"
        [[ ! "$chosen_a_kbps" =~ ^[0-9]+$ ]] && chosen_a_kbps=128
        if (( src_a_kbps < 64 )); then target_audio="64k"
        elif (( src_a_kbps < chosen_a_kbps )); then target_audio="${src_a_kbps}k"
        fi
    fi

    local -a cmd=(ffmpeg -hide_banner -loglevel error -nostats -progress pipe:1 -y -i "$INPUT_FILE")

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

    local total_frames="${SRC_FRAMES:-0}"
    [[ ! "$total_frames" =~ ^[0-9]+$ ]] && total_frames=0

    local errfile start_ts ff_status
    errfile=$(mktemp)
    start_ts=$(date +%s)

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
                    printf "%d\n", p
                    printf "# Frame %d of %d\n", f, total
                    fflush()
                    last = p
                }
            }
        }
        /^progress=end/ {
            print 100
            print "# Finalizing file..."
            fflush()
            exit
        }
    ' \
    | zenity --progress \
        --title="$TITLE — encoding" \
        --icon-name="media-playback-start" \
        --text="Starting ffmpeg..." \
        --percentage=0 --auto-close --width=480
    ff_status=${PIPESTATUS[0]}
    set -e

    local end; end=$(date +%s)
    local elapsed=$((end - start_ts))

    # --- Failure ---
    if (( ff_status != 0 )); then
        local raw_err=""
        [[ -s "$errfile" ]] && raw_err=$(tail -c 1200 "$errfile")
        rm -f "$errfile"
        [[ -e "$out" ]] && rm -f "$out"

        local reason
        reason=$(diagnose_ffmpeg_error "$ff_status" "$raw_err")

        local err_text=""
        if [[ -n "$raw_err" ]]; then
            err_text=$(printf '%s' "$raw_err" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        fi

        local msg
        msg="<b>Aw, the encode failed :(</b>\n\n"
        msg+="$reason\n\n"
        msg+="<small>File: $(xml_escape "$(basename "$INPUT_FILE")")  ·  ran for $(format_time "$elapsed")</small>"
        if [[ -n "$err_text" ]]; then
            msg+="\n\n<b>What ffmpeg actually said</b>\n<tt><small>${err_text}</small></tt>"
        fi

        if zenity --question --icon-name="dialog-error" --title="$TITLE — failed" \
            --width=560 --text="$msg" \
            --ok-label="Try again" --cancel-label="Give up"; then
            return 1
        else
            return 2
        fi
    fi
    rm -f "$errfile"

    if [[ ! -s "$out" ]]; then
        zenity --error --icon-name="dialog-error" --title="$TITLE" --width=460 \
            --text="<b>ffmpeg said it finished, but there's nothing there</b>\n\nIt claimed success, but the output file is missing or empty. That's a strange one."
        return 2
    fi

    # --- Success ---
    local insz outsz ratio
    insz=$(stat -c%s "$INPUT_FILE" 2>/dev/null || stat -f%z "$INPUT_FILE")
    outsz=$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out")
    ratio=$(awk -v a="$insz" -v b="$outsz" 'BEGIN{ if(a>0) printf "%.1f", (1-b/a)*100; else print "0" }')

    local grow_note=""
    if (( outsz > insz )); then
        grow_note="\n\n<small><i>The output is larger than the input — the source was already heavily compressed.</i></small>"
    fi

    local msg
    msg="<b>All done! :)</b>\n\n"
    msg+="<b>Time</b>     $(format_time "$elapsed")\n"
    msg+="<b>Input</b>    $(human_size "$insz")\n"
    msg+="<b>Output</b>   $(human_size "$outsz")\n"
    msg+="<b>Saved</b>    ${ratio}%${grow_note}\n\n"
    msg+="<b>Saved to</b>\n<small>$(xml_escape "$out")</small>"

    zenity --info --icon-name="dialog-information" --title="$TITLE — done" \
        --width=520 --text="$msg" --ok-label="OK"

    return 0
}

# ---------- Main ----------
detect_ffmpeg

while true; do
    if ! pick_file; then exit 0; fi

    probe_source "$INPUT_FILE"

    if [[ $HAVE_FFPROBE -eq 1 ]]; then
        zenity --info --icon-name="dialog-information" \
            --title="$TITLE — source info" --width=460 \
            --text="$(source_info_text)" \
            --ok-label="Continue" || exit 0
    fi

    while true; do
        KEEP_ALL_AUDIO=0; KEEP_SURROUND=0; KEEP_SUBTITLES=0
        AUDIO_BITRATE="128k"; TUNE=""; X264_PARAMS=""

        if ! pick_settings; then break; fi
        if ! pick_output;   then break; fi
        if ! confirm;       then break; fi

        do_compress
        rc=$?
        if (( rc == 0 )); then break
        elif (( rc == 2 )); then break
        fi
    done

    if ! zenity --question --icon-name="dialog-question" --title="$TITLE" \
        --width=340 --text="<b>Want to do another one?</b>" \
        --ok-label="Yes" --cancel-label="No"; then
        break
    fi
done

exit 0
