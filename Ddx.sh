#!/usr/bin/env bash
#
# ddx - universal dd disk imaging & cloning wizard
#
# One tool for every direction:
#   local disk  -> local image     local image  -> local disk
#   local disk  -> remote image    remote image -> local disk
#   remote disk -> local image     local image  -> remote disk
#   local disk  -> remote disk     remote disk  -> local disk
#   remote disk -> remote image    image        -> image (recompress)
#   remote disk -> remote disk (relayed through this machine)
#
# Compression: none | gzip | pigz | zstd | xz | lz4  (with levels)
# Compression always runs on the "smart" side so the SSH wire carries
# compressed data whenever possible.
#
# https://github.com/<your-user>/ddx
# License: MIT
#
set -o errexit -o nounset -o pipefail

VERSION="1.0.0"
SELF="$(basename "$0")"

# ---------------------------------------------------------------- colors ----
if [[ -t 2 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[34m' C_C=$'\e[36m' C_N=$'\e[0m' C_BOLD=$'\e[1m'
else
  C_R="" C_G="" C_Y="" C_B="" C_C="" C_N="" C_BOLD=""
fi

log()  { echo "${C_C}[ddx]${C_N} $*" >&2; }
ok()   { echo "${C_G}[ddx]${C_N} $*" >&2; }
warn() { echo "${C_Y}[ddx] WARNING:${C_N} $*" >&2; }
die()  { echo "${C_R}[ddx] ERROR:${C_N} $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
q()    { printf '%q' "$1"; }

# --------------------------------------------------------------- defaults ---
SRC_SPEC="" DST_SPEC=""
COMP=""            # none|gzip|pigz|zstd|xz|lz4  ("" = auto/ask)
LEVEL=""           # compression level ("" = default per tool)
BS="4M"
SSH_PORT="" SSH_KEY=""
WIRE="auto"        # transfer compression for raw disk->disk over ssh: auto|none|gzip|zstd|lz4
CHECKSUM=0
DRY_RUN=0
ASSUME_YES=0
REMOTE_SUDO=0
LIST_TARGET=""
DO_LIST=0

usage() {
cat <<EOF
${C_BOLD}ddx v$VERSION${C_N} - universal dd disk imaging & cloning wizard

${C_BOLD}USAGE${C_N}
  $SELF                         interactive wizard (recommended)
  $SELF -s SOURCE -d DEST [options]
  $SELF --list [user@host]      list disks (local or remote)

${C_BOLD}ENDPOINT SYNTAX${C_N} (rsync-style)
  /dev/sda                      local disk
  ./backups/sda.img.zst         local image file
  root@1.2.3.4:/dev/sda         remote disk
  root@1.2.3.4:/backup/x.img.gz remote image file

  Anything under /dev/ is treated as a block device; everything else
  as an image file. Compression of existing images is auto-detected
  from the extension (.gz .zst .xz .lz4).

${C_BOLD}OPTIONS${C_N}
  -s, --source SPEC       source endpoint
  -d, --dest SPEC         destination endpoint
  -c, --compression NAME  none|gzip|pigz|zstd|xz|lz4 (for image output;
                          default: inferred from dest extension, else zstd)
  -l, --level N           compression level (gzip/pigz 1-9, zstd 1-19,
                          xz 0-9, lz4 1-12)
  -b, --bs SIZE           dd block size (default: 4M)
  -p, --ssh-port PORT     SSH port for remote endpoints
  -i, --ssh-key FILE      SSH identity file
      --wire MODE         transfer compression for RAW streams over SSH
                          (disk->disk): auto|none|gzip|zstd|lz4 (default: auto)
      --remote-sudo       prefix remote dd with 'sudo -n' (needs NOPASSWD)
      --checksum          write a .sha256 next to created images
  -n, --dry-run           print the pipeline, do not run it
  -y, --yes               skip confirmations (DANGEROUS with disks)
      --list [HOST]       list local (or remote) disks and exit
  -h, --help              this help
  -V, --version           print version

${C_BOLD}EXAMPLES${C_N}
  # backup local disk to compressed local image
  $SELF -s /dev/sda -d ./sda.img.zst -c zstd -l 3

  # backup local disk straight to a remote server
  $SELF -s /dev/sda -d root@10.0.0.5:/backup/web1-sda.img.gz -c gzip -l 6

  # pull a remote server's disk down to a local image
  $SELF -s root@10.0.0.5:/dev/sda -d ./web1.img.zst

  # restore an image onto a remote server's disk
  $SELF -s ./web1.img.zst -d root@10.0.0.9:/dev/sda

  # clone one server's disk directly onto another server's disk
  $SELF -s root@old:/dev/sda -d root@new:/dev/sda --wire zstd

  # recompress an image (gzip -> zstd)
  $SELF -s ./old.img.gz -d ./old.img.zst -c zstd -l 10
EOF
}

# ----------------------------------------------------------- arg parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--source)      SRC_SPEC="${2:?missing value for $1}"; shift 2;;
    -d|--dest)        DST_SPEC="${2:?missing value for $1}"; shift 2;;
    -c|--compression) COMP="${2:?}"; shift 2;;
    -l|--level)       LEVEL="${2:?}"; shift 2;;
    -b|--bs)          BS="${2:?}"; shift 2;;
    -p|--ssh-port)    SSH_PORT="${2:?}"; shift 2;;
    -i|--ssh-key)     SSH_KEY="${2:?}"; shift 2;;
    --wire)           WIRE="${2:?}"; shift 2;;
    --remote-sudo)    REMOTE_SUDO=1; shift;;
    --checksum)       CHECKSUM=1; shift;;
    -n|--dry-run)     DRY_RUN=1; shift;;
    -y|--yes)         ASSUME_YES=1; shift;;
    --list)           DO_LIST=1
                      if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then LIST_TARGET="$2"; shift; fi
                      shift;;
    -h|--help)        usage; exit 0;;
    -V|--version)     echo "ddx $VERSION"; exit 0;;
    *)                die "unknown option: $1 (see --help)";;
  esac
done

# --------------------------------------------------------------- ssh args ---
SSH_STR="ssh -o Compression=no"
[[ -n "$SSH_PORT" ]] && SSH_STR+=" -p $(q "$SSH_PORT")"
[[ -n "$SSH_KEY"  ]] && SSH_STR+=" -i $(q "$SSH_KEY")"

remote_run() { # host, command-string
  # shellcheck disable=SC2086
  eval "$SSH_STR $(q "$1") $(q "$2")"
}

# ------------------------------------------------------------- disk lists ---
list_disks_local() {
  echo "${C_BOLD}Local disks:${C_N}"
  lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL 2>/dev/null || lsblk -d
}
list_disks_remote() {
  echo "${C_BOLD}Disks on $1:${C_N}"
  remote_run "$1" "lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null || lsblk -d" || warn "could not list disks on $1"
}
if [[ $DO_LIST -eq 1 ]]; then
  if [[ -n "$LIST_TARGET" ]]; then list_disks_remote "$LIST_TARGET"; else list_disks_local; fi
  exit 0
fi

# ------------------------------------------------------ endpoint parsing ----
# sets: <P>_HOST <P>_PATH <P>_REMOTE(0/1) <P>_DISK(0/1) <P>_COMP(ext-detected)
parse_endpoint() {
  local spec="$1" p="$2" host="" path=""
  if [[ "$spec" =~ ^(([A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+):(.+)$ && "${spec:0:1}" != "/" && "${spec:0:2}" != "./" ]]; then
    host="${BASH_REMATCH[1]}"; path="${BASH_REMATCH[3]}"
  else
    host=""; path="$spec"
  fi
  local remote=0 disk=0
  [[ -n "$host" ]] && remote=1
  [[ "$path" == /dev/* ]] && disk=1
  printf -v "${p}_HOST"   '%s' "$host"
  printf -v "${p}_PATH"   '%s' "$path"
  printf -v "${p}_REMOTE" '%s' "$remote"
  printf -v "${p}_DISK"   '%s' "$disk"
  printf -v "${p}_COMP"   '%s' "$(comp_from_ext "$path")"
}

comp_from_ext() {
  case "$1" in
    *.gz)  echo gzip;;
    *.zst) echo zstd;;
    *.xz)  echo xz;;
    *.lz4) echo lz4;;
    *)     echo none;;
  esac
}

ext_for_comp() {
  case "$1" in
    gzip|pigz) echo ".gz";;
    zstd)      echo ".zst";;
    xz)        echo ".xz";;
    lz4)       echo ".lz4";;
    *)         echo "";;
  esac
}

default_level() {
  case "$1" in
    gzip|pigz) echo 6;;
    zstd)      echo 3;;
    xz)        echo 6;;
    lz4)       echo 1;;
    *)         echo "";;
  esac
}

level_range() {
  case "$1" in
    gzip|pigz) echo "1-9";;
    zstd)      echo "1-19";;
    xz)        echo "0-9";;
    lz4)       echo "1-12";;
  esac
}

comp_cmd() { # name level
  case "$1" in
    gzip) echo "gzip -c -${2}";;
    pigz) echo "pigz -c -${2}";;
    zstd) echo "zstd -q -c -${2} -T0";;
    xz)   echo "xz -c -${2} -T0";;
    lz4)  echo "lz4 -q -c -${2}";;
    none) echo "";;
  esac
}

decomp_cmd() { # family (gz produced by gzip OR pigz)
  case "$1" in
    gzip|pigz) if have pigz; then echo "pigz -dc"; else echo "gzip -dc"; fi;;
    zstd)      echo "zstd -q -dc";;
    xz)        echo "xz -dc -T0";;
    lz4)       echo "lz4 -q -dc";;
    none)      echo "";;
  esac
}

# decompressor name to use on a given side; on remote side we can't know
# if pigz exists without asking, so remote decompression uses the portable tool
decomp_cmd_remote() {
  case "$1" in
    gzip|pigz) echo "gzip -dc";;
    zstd)      echo "zstd -q -dc";;
    xz)        echo "xz -dc";;
    lz4)       echo "lz4 -q -dc";;
    none)      echo "";;
  esac
}

# --------------------------------------------------------------- helpers ----
ask() { # prompt [default] -> echoes answer
  local prompt="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then
    read -rp "${C_B}?${C_N} $prompt [${def}]: " ans; echo "${ans:-$def}"
  else
    read -rp "${C_B}?${C_N} $prompt: " ans; echo "$ans"
  fi
}

ask_yn() { # prompt default(y/n)
  local a; a="$(ask "$1 (y/n)" "$2")"
  [[ "$a" =~ ^[Yy] ]]
}

human_size() {
  local b="$1"
  if [[ -z "$b" ]]; then echo "?"; return; fi
  awk -v b="$b" 'BEGIN{ s="B K M G T P"; split(s,u," "); i=1;
    while (b>=1024 && i<6) { b/=1024; i++ } printf "%.1f%s", b, u[i] }'
}

get_size_bytes() { # remote(0/1) host path disk(0/1) -> bytes or ""
  local remote="$1" host="$2" path="$3" disk="$4" out=""
  if [[ "$remote" -eq 0 ]]; then
    if [[ "$disk" -eq 1 ]]; then
      out="$(blockdev --getsize64 "$path" 2>/dev/null || lsblk -bdno SIZE "$path" 2>/dev/null | head -1 || true)"
    else
      out="$(stat -c %s "$path" 2>/dev/null || true)"
    fi
  else
    if [[ "$disk" -eq 1 ]]; then
      out="$(remote_run "$host" "blockdev --getsize64 $(q "$path") 2>/dev/null || lsblk -bdno SIZE $(q "$path") 2>/dev/null | head -1" 2>/dev/null || true)"
    else
      out="$(remote_run "$host" "stat -c %s $(q "$path") 2>/dev/null" 2>/dev/null || true)"
    fi
  fi
  [[ "$out" =~ ^[0-9]+$ ]] && echo "$out" || echo ""
}

check_mounted_local() { # path -> dies if mounted
  local p="$1"
  if lsblk -no MOUNTPOINT "$p" 2>/dev/null | grep -q '[^[:space:]]'; then
    die "$p (or one of its partitions) is MOUNTED. Unmount it first."
  fi
}

check_mounted_remote() { # host path -> warns
  if remote_run "$1" "lsblk -no MOUNTPOINT $(q "$2") 2>/dev/null | grep -q '[^[:space:]]'" 2>/dev/null; then
    if [[ $ASSUME_YES -eq 1 ]]; then
      warn "$2 on $1 appears to be MOUNTED - continuing because of --yes"
    else
      die "$2 on $1 (or one of its partitions) is MOUNTED. Unmount it first."
    fi
  fi
}

check_remote_tool() { # host tool
  remote_run "$1" "command -v $(q "$2") >/dev/null 2>&1" \
    || die "'$2' is not installed on $1 - install it there first (or choose another compression)"
}

confirm_disk_write() { # human-target-description device-path
  [[ $ASSUME_YES -eq 1 ]] && return 0
  echo
  echo "${C_R}${C_BOLD}  !!! ALL DATA ON $1 WILL BE PERMANENTLY DESTROYED !!!${C_N}"
  echo
  local a
  read -rp "  Type the device path ($2) to confirm: " a
  [[ "$a" == "$2" ]] || die "confirmation did not match - aborted"
}

# ---------------------------------------------------------------- wizard ----
wizard_endpoint() { # role(source|dest) -> echoes spec
  local role="$1" spec="" host="" hp="" kind loc
  echo >&2
  echo "${C_BOLD}--- ${role^^} ---${C_N}" >&2
  loc="$(ask "Is the $role LOCAL or REMOTE? (l/r)" "l")"
  if [[ "$loc" =~ ^[Rr] ]]; then
    host="$(ask "Remote SSH target (user@host)")"
    [[ -n "$host" ]] || die "no host given"
    if [[ -z "$SSH_PORT" ]]; then
      hp="$(ask "SSH port" "22")"
      [[ "$hp" != "22" ]] && { SSH_PORT="$hp"; SSH_STR+=" -p $(q "$SSH_PORT")"; }
    fi
  fi
  kind="$(ask "Is the $role a DISK (block device) or an IMAGE file? (d/i)" "d")"
  if [[ "$kind" =~ ^[Dd] ]]; then
    if [[ -n "$host" ]]; then list_disks_remote "$host" >&2 || true; else list_disks_local >&2; fi
    local dev; dev="$(ask "Device path (e.g. /dev/sda)")"
    [[ "$dev" == /dev/* ]] || die "a disk must be under /dev/"
    spec="$dev"
  else
    local f; f="$(ask "Image file path (e.g. ./sda.img.zst)")"
    [[ -n "$f" ]] || die "no path given"
    spec="$f"
  fi
  [[ -n "$host" ]] && spec="$host:$spec"
  echo "$spec"
}

run_wizard() {
  echo "${C_BOLD}ddx v$VERSION - universal dd imaging & cloning wizard${C_N}" >&2
  echo "Answer a few questions and gooo." >&2
  SRC_SPEC="$(wizard_endpoint "source")"
  DST_SPEC="$(wizard_endpoint "destination")"
}

# =================================================================== MAIN ===
[[ -z "$SRC_SPEC" && -z "$DST_SPEC" ]] && run_wizard
[[ -n "$SRC_SPEC" ]] || die "no source given (use -s or run the wizard)"
[[ -n "$DST_SPEC" ]] || die "no destination given (use -d or run the wizard)"

parse_endpoint "$SRC_SPEC" SRC
parse_endpoint "$DST_SPEC" DST

# sanity
[[ "$SRC_SPEC" == "$DST_SPEC" ]] && die "source and destination are the same"
if [[ $SRC_REMOTE -eq 0 && $SRC_DISK -eq 0 && ! -e "$SRC_PATH" ]]; then
  die "source image not found: $SRC_PATH"
fi
if [[ $SRC_REMOTE -eq 0 && $SRC_DISK -eq 1 && ! -b "$SRC_PATH" ]]; then
  die "source is not a block device: $SRC_PATH"
fi
if [[ $DST_REMOTE -eq 0 && $DST_DISK -eq 1 && ! -b "$DST_PATH" ]]; then
  die "destination is not a block device: $DST_PATH"
fi

# ------------------------------------------ choose compression for images ---
if [[ $DST_DISK -eq 0 ]]; then
  if [[ -z "$COMP" ]]; then
    if [[ "$DST_COMP" != "none" ]]; then
      COMP="$DST_COMP"
    elif [[ -z "$SRC_SPEC" || $DRY_RUN -eq 1 || $ASSUME_YES -eq 1 ]]; then
      COMP="none"
    else
      # interactive choice
      avail="none gzip"
      have pigz && avail+=" pigz"
      have zstd && avail+=" zstd"
      have xz   && avail+=" xz"
      have lz4  && avail+=" lz4"
      def="zstd"; have zstd || def="gzip"
      COMP="$(ask "Compression for the image ($avail)" "$def")"
    fi
  fi
  case "$COMP" in none|gzip|pigz|zstd|xz|lz4) ;; *) die "unknown compression: $COMP";; esac
  if [[ "$COMP" != "none" ]]; then
    if [[ -z "$LEVEL" ]]; then
      if [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]]; then
        LEVEL="$(default_level "$COMP")"
      else
        LEVEL="$(ask "Compression level ($(level_range "$COMP"))" "$(default_level "$COMP")")"
      fi
    fi
    [[ "$LEVEL" =~ ^[0-9]+$ ]] || die "compression level must be a number"
  fi
  # warn about mismatched extension
  want_ext="$(ext_for_comp "$COMP")"
  if [[ -n "$want_ext" && "$DST_PATH" != *"$want_ext" ]]; then
    warn "destination '$DST_PATH' does not end in $want_ext - restore will rely on you remembering the format"
  fi
  if [[ "$COMP" == "none" && "$DST_COMP" != "none" ]]; then
    warn "destination extension suggests $DST_COMP but compression is 'none'"
  fi
else
  COMP="none"   # writing to a disk: final stream must be raw
fi

# local tool availability
if [[ "$COMP" != "none" ]]; then
  case "$COMP" in gzip) : ;; *) have "$COMP" || { [[ $SRC_REMOTE -eq 1 ]] || die "'$COMP' is not installed locally"; } ;; esac
fi

# ---------------------------------------------------- build the pipeline ----
# stream_comp = compression of the byte stream as it leaves the producer
stream_comp="none"
[[ $SRC_DISK -eq 0 ]] && stream_comp="$SRC_COMP"

producer=""; src_filters=(); dst_filters=(); consumer=""
crossing_ssh=$(( SRC_REMOTE || DST_REMOTE ))

# producer (runs on the source side)
if [[ $SRC_DISK -eq 1 ]]; then
  producer="dd if=$(q "$SRC_PATH") bs=$(q "$BS") status=none"
  [[ $SRC_REMOTE -eq 1 && $REMOTE_SUDO -eq 1 ]] && producer="sudo -n $producer"
else
  producer="cat $(q "$SRC_PATH")"
fi

if [[ $DST_DISK -eq 1 ]]; then
  # destination needs RAW; decompress on the destination side so the SSH
  # wire carries compressed bytes
  if [[ "$stream_comp" != "none" ]]; then
    if [[ $DST_REMOTE -eq 1 ]]; then
      dst_filters+=("$(decomp_cmd_remote "$stream_comp")")
    else
      dst_filters+=("$(decomp_cmd "$stream_comp")")
    fi
  elif [[ $crossing_ssh -eq 1 && "$WIRE" != "none" ]]; then
    # raw stream over the network: optional transfer compression
    wsel="$WIRE"
    if [[ "$wsel" == "auto" ]]; then
      if have zstd; then wsel="zstd"; elif have lz4; then wsel="lz4"; else wsel="gzip"; fi
    fi
    case "$wsel" in gzip|zstd|lz4) ;; *) die "--wire must be auto|none|gzip|zstd|lz4";; esac
    wlevel=1
    src_filters+=("$(comp_cmd "$wsel" "$wlevel")")
    if [[ $DST_REMOTE -eq 1 ]]; then
      dst_filters+=("$(decomp_cmd_remote "$wsel")")
    else
      dst_filters+=("$(decomp_cmd "$wsel")")
    fi
    WIRE_USED="$wsel"
  fi
  consumer="dd of=$(q "$DST_PATH") bs=$(q "$BS") iflag=fullblock conv=fsync status=none"
  [[ $DST_REMOTE -eq 1 && $REMOTE_SUDO -eq 1 ]] && consumer="sudo -n $consumer"
else
  # destination is an image with target compression $COMP
  if [[ "$stream_comp" != "$COMP" ]]; then
    # transcode on the SOURCE side so the wire carries the final format
    if [[ "$stream_comp" != "none" ]]; then
      if [[ $SRC_REMOTE -eq 1 ]]; then
        src_filters+=("$(decomp_cmd_remote "$stream_comp")")
      else
        src_filters+=("$(decomp_cmd "$stream_comp")")
      fi
    fi
    if [[ "$COMP" != "none" ]]; then
      src_filters+=("$(comp_cmd "$COMP" "$LEVEL")")
    fi
  fi
  consumer="cat > $(q "$DST_PATH")"
fi

# remote tool checks (best effort, before we start writing anything)
if [[ $DRY_RUN -eq 0 && $SRC_REMOTE -eq 1 ]]; then
  for f in "${src_filters[@]}"; do
    check_remote_tool "$SRC_HOST" "${f%% *}"
  done
fi
if [[ $DRY_RUN -eq 0 && $DST_REMOTE -eq 1 ]]; then
  for f in "${dst_filters[@]}"; do
    check_remote_tool "$DST_HOST" "${f%% *}"
  done
fi

# assemble left (source side)
left="$producer"
for f in "${src_filters[@]}"; do left+=" | $f"; done
if [[ $SRC_REMOTE -eq 1 ]]; then
  left="$SSH_STR $(q "$SRC_HOST") $(q "$left")"
fi

# assemble right (destination side)
right=""
for f in "${dst_filters[@]}"; do
  [[ -n "$right" ]] && right+=" | "
  right+="$f"
done
if [[ -n "$right" ]]; then right+=" | $consumer"; else right="$consumer"; fi
if [[ $DST_REMOTE -eq 1 ]]; then
  right="$SSH_STR $(q "$DST_HOST") $(q "$right")"
fi

# local middle: progress + optional checksum
middle=()
src_bytes=""
if [[ $DRY_RUN -eq 0 || $SRC_REMOTE -eq 0 ]]; then
  src_bytes="$(get_size_bytes "$SRC_REMOTE" "$SRC_HOST" "$SRC_PATH" "$SRC_DISK")"
fi

pv_size_known=0
if [[ -n "$src_bytes" ]]; then
  # pv sits right after the stream enters the local machine; size is only
  # meaningful if no source-side transform changed the byte count
  if [[ ${#src_filters[@]} -eq 0 ]]; then pv_size_known=1; fi
  # ...unless source is local: then pv can go BEFORE local src filters
  if [[ $SRC_REMOTE -eq 0 ]]; then pv_size_known=1; fi
fi

if have pv; then
  pv_cmd="pv -pterab"
  [[ $pv_size_known -eq 1 ]] && pv_cmd+=" -s $src_bytes"
  middle+=("$pv_cmd")
else
  warn "'pv' not installed - no progress bar (apt install pv / yum install pv)"
fi

SHA_TMP=""
if [[ $CHECKSUM -eq 1 ]]; then
  if [[ $DST_DISK -eq 1 ]]; then
    warn "--checksum only applies when creating images - ignored"
  else
    SHA_TMP="$(mktemp)"
    middle+=("tee >(sha256sum > $(q "$SHA_TMP"))")
  fi
fi

# position of pv: if source is local, put pv straight after the raw producer
# (before local compression) so -s matches; easiest correct assembly:
if [[ $SRC_REMOTE -eq 0 && ${#src_filters[@]} -gt 0 && "$(have pv && echo 1)" == "1" ]]; then
  # rebuild left with pv injected after producer
  left="$producer | ${middle[0]}"
  for f in "${src_filters[@]}"; do left+=" | $f"; done
  middle=("${middle[@]:1}")   # pv consumed
fi

pipeline="$left"
for m in "${middle[@]}"; do pipeline+=" | $m"; done
pipeline+=" | $right"

# ----------------------------------------------------------------- summary --
fmt_ep() { # remote host path disk comp
  local s=""
  [[ "$1" -eq 1 ]] && s+="remote ($2) " || s+="local "
  [[ "$4" -eq 1 ]] && s+="disk $3" || s+="image $3"
  [[ "$4" -eq 0 && "$5" != "none" ]] && s+=" [$5]"
  echo "$s"
}

echo >&2
echo "${C_BOLD}================ PLAN ================${C_N}" >&2
echo "  Source : $(fmt_ep "$SRC_REMOTE" "$SRC_HOST" "$SRC_PATH" "$SRC_DISK" "$SRC_COMP")" >&2
echo "  Dest   : $(fmt_ep "$DST_REMOTE" "$DST_HOST" "$DST_PATH" "$DST_DISK" "$COMP")" >&2
[[ -n "$src_bytes" ]] && echo "  Size   : $(human_size "$src_bytes") ($src_bytes bytes)" >&2
[[ $DST_DISK -eq 0 && "$COMP" != "none" ]] && echo "  Comp   : $COMP level $LEVEL" >&2
[[ -n "${WIRE_USED:-}" ]] && echo "  Wire   : transfer-compressed with $WIRE_USED (level 1)" >&2
echo "  BS     : $BS" >&2
echo "  Pipe   : $pipeline" >&2
echo "${C_BOLD}======================================${C_N}" >&2
echo >&2

if [[ $DRY_RUN -eq 1 ]]; then
  ok "dry run - nothing executed"
  exit 0
fi

# ---------------------------------------------------------------- safety ----
# destination size check for disk targets
if [[ $DST_DISK -eq 1 && -n "$src_bytes" && "$stream_comp" == "none" && $SRC_DISK -eq 1 ]]; then
  dst_bytes="$(get_size_bytes "$DST_REMOTE" "$DST_HOST" "$DST_PATH" 1)"
  if [[ -n "$dst_bytes" && "$dst_bytes" -lt "$src_bytes" ]]; then
    warn "destination disk ($(human_size "$dst_bytes")) is SMALLER than source ($(human_size "$src_bytes")) - the copy will be truncated"
    [[ $ASSUME_YES -eq 1 ]] || ask_yn "Continue anyway?" "n" || die "aborted"
  fi
fi

# mounted checks + permissions
if [[ $SRC_DISK -eq 1 && $SRC_REMOTE -eq 0 ]]; then
  [[ -r "$SRC_PATH" ]] || die "cannot read $SRC_PATH - run with sudo"
fi
if [[ $DST_DISK -eq 1 ]]; then
  if [[ $DST_REMOTE -eq 0 ]]; then
    [[ -w "$DST_PATH" ]] || die "cannot write to $DST_PATH - run with sudo"
    check_mounted_local "$DST_PATH"
    confirm_disk_write "$DST_PATH (local)" "$DST_PATH"
  else
    check_mounted_remote "$DST_HOST" "$DST_PATH"
    confirm_disk_write "$DST_PATH on $DST_HOST" "$DST_PATH"
  fi
fi

# create parent dir for local image dest
if [[ $DST_DISK -eq 0 && $DST_REMOTE -eq 0 ]]; then
  mkdir -p "$(dirname "$DST_PATH")"
fi
if [[ $DST_DISK -eq 0 && $DST_REMOTE -eq 1 ]]; then
  remote_run "$DST_HOST" "mkdir -p $(q "$(dirname "$DST_PATH")")" || true
fi

# ------------------------------------------------------------------- run ----
log "starting at $(date '+%F %T')"
t0=$SECONDS

set +e
eval "$pipeline"
rc=$?
set -e
[[ $rc -ne 0 ]] && die "pipeline failed with exit code $rc"

elapsed=$(( SECONDS - t0 ))
sync 2>/dev/null || true

# checksum finalize
if [[ -n "$SHA_TMP" ]]; then
  for _ in $(seq 1 50); do [[ -s "$SHA_TMP" ]] && break; sleep 0.1; done
  if [[ -s "$SHA_TMP" ]]; then
    hash="$(awk '{print $1}' "$SHA_TMP")"
    if [[ $DST_REMOTE -eq 0 ]]; then
      shafile="${DST_PATH}.sha256"
    else
      shafile="./$(basename "$DST_PATH").sha256"
      warn "destination is remote - checksum saved locally as $shafile"
    fi
    echo "$hash  $(basename "$DST_PATH")" > "$shafile"
    ok "sha256: $hash  -> $shafile"
  else
    warn "checksum could not be captured"
  fi
  rm -f "$SHA_TMP"
fi

ok "done in ${elapsed}s"
if [[ $DST_DISK -eq 0 && $DST_REMOTE -eq 0 && -f "$DST_PATH" ]]; then
  ok "image size: $(human_size "$(stat -c %s "$DST_PATH")") -> $DST_PATH"
fi
