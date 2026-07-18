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
# SSH auth per endpoint: agent/config defaults, key file, or password
# (via sshpass). Connection multiplexing (ControlMaster) means you
# authenticate ONCE per host per run, no matter how many checks run.
#
# https://github.com/<your-user>/ddx
# License: MIT
#
set -o errexit -o nounset -o pipefail

VERSION="1.1.0"
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
WIRE="auto"        # transfer compression for raw disk->disk over ssh
CHECKSUM=0
DRY_RUN=0
ASSUME_YES=0
REMOTE_SUDO=0
ASK_PASS=0
LIST_TARGET=""
DO_LIST=0

# per-endpoint SSH auth (filled by the wizard or --ask-pass / -i)
# shellcheck disable=SC2034  # referenced indirectly via ${!var}
SRC_HOST="" SRC_KEY="" SRC_PASS=""
# shellcheck disable=SC2034
DST_HOST="" DST_KEY="" DST_PASS=""

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
  -i, --ssh-key FILE      SSH identity file (applies to all remote hosts)
  -P, --ask-pass          prompt for SSH password(s) for remote hosts
                          (uses sshpass; hidden input, never on the cmdline)
      --wire MODE         transfer compression for RAW streams over SSH
                          (disk->disk): auto|none|gzip|zstd|lz4 (default: auto)
      --remote-sudo       prefix remote dd with 'sudo -n' (needs NOPASSWD)
      --checksum          write a .sha256 next to created images
  -n, --dry-run           print the pipeline, do not run it
  -y, --yes               skip confirmations (DANGEROUS with disks)
      --list [HOST]       list local (or remote) disks and exit
  -h, --help              this help
  -V, --version           print version

${C_BOLD}SSH AUTHENTICATION${C_N}
  The wizard asks per remote host: (d)efault agent/~/.ssh/config,
  (k)ey file, or (p)assword. Password auth uses 'sshpass' if installed;
  without it, ssh prompts you interactively - but thanks to connection
  multiplexing you only type it ONCE per host either way.

${C_BOLD}EXAMPLES${C_N}
  # backup local disk to compressed local image
  $SELF -s /dev/sda -d ./sda.img.zst -c zstd -l 3

  # backup local disk straight to a remote server (password auth)
  $SELF -s /dev/sda -d root@10.0.0.5:/backup/web1.img.gz -c gzip -P

  # pull a remote server's disk down to a local image (key auth)
  $SELF -s root@10.0.0.5:/dev/sda -d ./web1.img.zst -i ~/.ssh/backup_key

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
    -P|--ask-pass)    ASK_PASS=1; shift;;
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

# --------------------------------------------- ssh base + multiplexing ------
CTL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ddx-ssh.XXXXXX")"
cleanup() {
  local p hv h
  for p in SRC DST; do
    hv="${p}_HOST"; h="${!hv-}"
    if [[ -n "$h" ]]; then
      # shellcheck disable=SC2086
      eval "$(ssh_for "$p") -O exit $(q "$h")" >/dev/null 2>&1 || true
    fi
  done
  rm -rf "$CTL_DIR"
}
trap cleanup EXIT

SSH_BASE="ssh -o Compression=no -o ConnectTimeout=10"
SSH_BASE+=" -o ControlMaster=auto -o ControlPath=$(q "$CTL_DIR")/%C -o ControlPersist=60"
[[ -n "$SSH_PORT" ]] && SSH_BASE+=" -p $(q "$SSH_PORT")"
[[ -n "$SSH_KEY"  ]] && SSH_BASE+=" -i $(q "$SSH_KEY")"

# full ssh invocation prefix for one endpoint (SRC|DST), without the host
ssh_for() {
  local p="$1"
  local kv="${p}_KEY" pv="${p}_PASS"
  local key="${!kv-}" pass="${!pv-}" s="$SSH_BASE"
  [[ -n "$key" ]] && s+=" -i $(q "$key")"
  if [[ -n "$pass" ]] && have sshpass; then
    s="SSHPASS=$(q "$pass") sshpass -e $s"
  fi
  echo "$s"
}

remote_run() { # SRC|DST, command-string
  local p="$1" hv="${1}_HOST"; local host="${!hv}"
  # shellcheck disable=SC2086
  eval "$(ssh_for "$p") $(q "$host") $(q "$2")"
}

read_password() { # SRC|DST host
  local p="$1" host="$2" pw
  if ! have sshpass; then
    warn "sshpass is not installed - ssh itself will ask for the password of $host"
    warn "(only once, thanks to connection sharing). To avoid prompts: apt install sshpass"
    return 0
  fi
  read -rsp "${C_B}?${C_N} SSH password for $host: " pw >&2; echo >&2
  printf -v "${p}_PASS" '%s' "$pw"
}

# ------------------------------------------------------------- disk lists ---
list_disks_local() {
  echo "${C_BOLD}Local disks:${C_N}"
  lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL 2>/dev/null || lsblk -d
}
list_disks_remote() { # SRC|DST
  local hv="${1}_HOST"
  echo "${C_BOLD}Disks on ${!hv}:${C_N}"
  remote_run "$1" "lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null || lsblk -d" \
    || warn "could not list disks on ${!hv}"
}
if [[ $DO_LIST -eq 1 ]]; then
  if [[ -n "$LIST_TARGET" ]]; then
    SRC_HOST="$LIST_TARGET"
    [[ $ASK_PASS -eq 1 ]] && read_password SRC "$SRC_HOST"
    list_disks_remote SRC
  else
    list_disks_local
  fi
  exit 0
fi

# ------------------------------------------------------ endpoint parsing ----
comp_from_ext() {
  case "$1" in
    *.gz)  echo gzip;;
    *.zst) echo zstd;;
    *.xz)  echo xz;;
    *.lz4) echo lz4;;
    *)     echo none;;
  esac
}

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

# remote side: use only the portable tool names
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

get_size_bytes() { # SRC|DST -> bytes or ""
  local p="$1"
  local rv="${p}_REMOTE" pv2="${p}_PATH" dv="${p}_DISK"
  local remote="${!rv}" path="${!pv2}" disk="${!dv}" out=""
  if [[ "$remote" -eq 0 ]]; then
    if [[ "$disk" -eq 1 ]]; then
      out="$(blockdev --getsize64 "$path" 2>/dev/null || lsblk -bdno SIZE "$path" 2>/dev/null | head -1 || true)"
    else
      out="$(stat -c %s "$path" 2>/dev/null || true)"
    fi
  else
    if [[ "$disk" -eq 1 ]]; then
      out="$(remote_run "$p" "blockdev --getsize64 $(q "$path") 2>/dev/null || lsblk -bdno SIZE $(q "$path") 2>/dev/null | head -1" 2>/dev/null || true)"
    else
      out="$(remote_run "$p" "stat -c %s $(q "$path") 2>/dev/null" 2>/dev/null || true)"
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

check_mounted_remote() { # SRC|DST
  local hv="${1}_HOST" pv2="${1}_PATH"
  if remote_run "$1" "lsblk -no MOUNTPOINT $(q "${!pv2}") 2>/dev/null | grep -q '[^[:space:]]'" 2>/dev/null; then
    if [[ $ASSUME_YES -eq 1 ]]; then
      warn "${!pv2} on ${!hv} appears to be MOUNTED - continuing because of --yes"
    else
      die "${!pv2} on ${!hv} (or one of its partitions) is MOUNTED. Unmount it first."
    fi
  fi
}

check_remote_tool() { # SRC|DST tool
  local hv="${1}_HOST"
  remote_run "$1" "command -v $(q "$2") >/dev/null 2>&1" \
    || die "'$2' is not installed on ${!hv} - install it there first (or choose another compression)"
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
wizard_endpoint() { # P(SRC|DST) role-label -> sets WIZ_SPEC + ${P}_* auth vars
  local P="$1" role="$2" spec="" host="" hp="" kind loc auth keyfile def
  echo >&2
  echo "${C_BOLD}--- ${role^^} ---${C_N}" >&2
  loc="$(ask "Is the $role LOCAL or REMOTE? (l/r)" "l")"
  if [[ "$loc" =~ ^[Rr] ]]; then
    host="$(ask "Remote SSH target (user@host)")"
    [[ -n "$host" ]] || die "no host given"
    printf -v "${P}_HOST" '%s' "$host"
    if [[ -z "$SSH_PORT" ]]; then
      hp="$(ask "SSH port" "22")"
      if [[ "$hp" != "22" ]]; then
        SSH_PORT="$hp"; SSH_BASE+=" -p $(q "$SSH_PORT")"
      fi
    fi
    # --- authentication ---
    auth="$(ask "SSH auth for $host: (d)efault agent/config, (k)ey file, (p)assword" "d")"
    case "$auth" in
      [Kk]*)
        def=""
        for f in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
          [[ -f "$f" ]] && { def="$f"; break; }
        done
        keyfile="$(ask "Path to private key" "$def")"
        [[ -f "$keyfile" ]] || die "key file not found: $keyfile"
        printf -v "${P}_KEY" '%s' "$keyfile"
        ;;
      [Pp]*)
        read_password "$P" "$host"
        ;;
      *) : ;;  # default: agent / ~/.ssh/config
    esac
  fi
  kind="$(ask "Is the $role a DISK (block device) or an IMAGE file? (d/i)" "d")"
  if [[ "$kind" =~ ^[Dd] ]]; then
    if [[ -n "$host" ]]; then list_disks_remote "$P" >&2 || true; else list_disks_local >&2; fi
    local dev; dev="$(ask "Device path (e.g. /dev/sda)")"
    [[ "$dev" == /dev/* ]] || die "a disk must be under /dev/"
    spec="$dev"
  else
    local f2; f2="$(ask "Image file path (e.g. ./sda.img.zst)")"
    [[ -n "$f2" ]] || die "no path given"
    spec="$f2"
  fi
  [[ -n "$host" ]] && spec="$host:$spec"
  WIZ_SPEC="$spec"
}

run_wizard() {
  echo "${C_BOLD}ddx v$VERSION - universal dd imaging & cloning wizard${C_N}" >&2
  echo "Answer a few questions and gooo." >&2
  wizard_endpoint SRC "source";      SRC_SPEC="$WIZ_SPEC"
  wizard_endpoint DST "destination"; DST_SPEC="$WIZ_SPEC"
}

# =================================================================== MAIN ===
WIZARD_USED=0
if [[ -z "$SRC_SPEC" && -z "$DST_SPEC" ]]; then WIZARD_USED=1; run_wizard; fi
[[ -n "$SRC_SPEC" ]] || die "no source given (use -s or run the wizard)"
[[ -n "$DST_SPEC" ]] || die "no destination given (use -d or run the wizard)"

parse_endpoint "$SRC_SPEC" SRC
parse_endpoint "$DST_SPEC" DST

# --ask-pass for CLI mode: prompt per remote host (skip if wizard already did)
if [[ $ASK_PASS -eq 1 && $WIZARD_USED -eq 0 ]]; then
  [[ $SRC_REMOTE -eq 1 && -z "$SRC_PASS" ]] && read_password SRC "$SRC_HOST"
  if [[ $DST_REMOTE -eq 1 && -z "$DST_PASS" ]]; then
    if [[ "$DST_HOST" == "$SRC_HOST" ]]; then DST_PASS="$SRC_PASS"; else read_password DST "$DST_HOST"; fi
  fi
fi

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

# ---------------------------------------------------------- ssh preflight ---
# connect early: opens the ControlMaster so every later ssh call (size probe,
# tool checks, mkdir, the pipeline itself) reuses ONE authenticated session
preflight_ssh() { # SRC|DST
  local hv="${1}_HOST"
  log "connecting to ${!hv} ..."
  remote_run "$1" "true" >/dev/null \
    || die "cannot connect to ${!hv} via SSH - check host, port (-p), key/password and firewall"
}
if [[ $DRY_RUN -eq 0 ]]; then
  [[ $SRC_REMOTE -eq 1 ]] && preflight_ssh SRC
  if [[ $DST_REMOTE -eq 1 && "$DST_HOST" != "$SRC_HOST" ]]; then preflight_ssh DST; fi
  if [[ $DST_REMOTE -eq 1 && "$DST_HOST" == "$SRC_HOST" && $SRC_REMOTE -eq 0 ]]; then preflight_ssh DST; fi
fi

# ------------------------------------------ choose compression for images ---
if [[ $DST_DISK -eq 0 ]]; then
  if [[ -z "$COMP" ]]; then
    if [[ "$DST_COMP" != "none" ]]; then
      COMP="$DST_COMP"
    elif [[ $DRY_RUN -eq 1 || $ASSUME_YES -eq 1 ]]; then
      COMP="none"
    else
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
stream_comp="none"
[[ $SRC_DISK -eq 0 ]] && stream_comp="$SRC_COMP"

producer=""; src_filters=(); dst_filters=(); consumer=""
crossing_ssh=$(( SRC_REMOTE || DST_REMOTE ))

if [[ $SRC_DISK -eq 1 ]]; then
  producer="dd if=$(q "$SRC_PATH") bs=$(q "$BS") status=none"
  [[ $SRC_REMOTE -eq 1 && $REMOTE_SUDO -eq 1 ]] && producer="sudo -n $producer"
else
  producer="cat $(q "$SRC_PATH")"
fi

if [[ $DST_DISK -eq 1 ]]; then
  if [[ "$stream_comp" != "none" ]]; then
    if [[ $DST_REMOTE -eq 1 ]]; then
      dst_filters+=("$(decomp_cmd_remote "$stream_comp")")
    else
      dst_filters+=("$(decomp_cmd "$stream_comp")")
    fi
  elif [[ $crossing_ssh -eq 1 && "$WIRE" != "none" ]]; then
    wsel="$WIRE"
    if [[ "$wsel" == "auto" ]]; then
      if have zstd; then wsel="zstd"; elif have lz4; then wsel="lz4"; else wsel="gzip"; fi
    fi
    case "$wsel" in gzip|zstd|lz4) ;; *) die "--wire must be auto|none|gzip|zstd|lz4";; esac
    src_filters+=("$(comp_cmd "$wsel" 1)")
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
  if [[ "$stream_comp" != "$COMP" ]]; then
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

# remote tool checks (cheap now - they reuse the multiplexed connection)
if [[ $DRY_RUN -eq 0 && $SRC_REMOTE -eq 1 ]]; then
  for f in "${src_filters[@]}"; do
    check_remote_tool SRC "${f%% *}"
  done
fi
if [[ $DRY_RUN -eq 0 && $DST_REMOTE -eq 1 ]]; then
  for f in "${dst_filters[@]}"; do
    check_remote_tool DST "${f%% *}"
  done
fi

# assemble left (source side)
left="$producer"
for f in "${src_filters[@]}"; do left+=" | $f"; done
if [[ $SRC_REMOTE -eq 1 ]]; then
  left="$(ssh_for SRC) $(q "$SRC_HOST") $(q "$left")"
fi

# assemble right (destination side)
right=""
for f in "${dst_filters[@]}"; do
  [[ -n "$right" ]] && right+=" | "
  right+="$f"
done
if [[ -n "$right" ]]; then right+=" | $consumer"; else right="$consumer"; fi
if [[ $DST_REMOTE -eq 1 ]]; then
  right="$(ssh_for DST) $(q "$DST_HOST") $(q "$right")"
fi

# local middle: progress + optional checksum
middle=()
src_bytes=""
if [[ $DRY_RUN -eq 0 || $SRC_REMOTE -eq 0 ]]; then
  src_bytes="$(get_size_bytes SRC)"
fi

pv_size_known=0
if [[ -n "$src_bytes" ]]; then
  if [[ ${#src_filters[@]} -eq 0 ]]; then pv_size_known=1; fi
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

# if source is local and has local filters, put pv right after the raw
# producer so -s matches the raw byte count
if [[ $SRC_REMOTE -eq 0 && ${#src_filters[@]} -gt 0 ]] && have pv; then
  left="$producer | ${middle[0]}"
  for f in "${src_filters[@]}"; do left+=" | $f"; done
  middle=("${middle[@]:1}")
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

# never print passwords in the plan
pipeline_display="$(sed -E 's/SSHPASS=[^[:space:]]+ sshpass -e /sshpass /g' <<<"$pipeline")"

echo >&2
echo "${C_BOLD}================ PLAN ================${C_N}" >&2
echo "  Source : $(fmt_ep "$SRC_REMOTE" "$SRC_HOST" "$SRC_PATH" "$SRC_DISK" "$SRC_COMP")" >&2
echo "  Dest   : $(fmt_ep "$DST_REMOTE" "$DST_HOST" "$DST_PATH" "$DST_DISK" "$COMP")" >&2
[[ -n "$src_bytes" ]] && echo "  Size   : $(human_size "$src_bytes") ($src_bytes bytes)" >&2
[[ $DST_DISK -eq 0 && "$COMP" != "none" ]] && echo "  Comp   : $COMP level $LEVEL" >&2
[[ -n "${WIRE_USED:-}" ]] && echo "  Wire   : transfer-compressed with $WIRE_USED (level 1)" >&2
echo "  BS     : $BS" >&2
echo "  Pipe   : $pipeline_display" >&2
echo "${C_BOLD}======================================${C_N}" >&2
echo >&2

if [[ $DRY_RUN -eq 1 ]]; then
  ok "dry run - nothing executed"
  exit 0
fi

# ---------------------------------------------------------------- safety ----
if [[ $DST_DISK -eq 1 && -n "$src_bytes" && "$stream_comp" == "none" && $SRC_DISK -eq 1 ]]; then
  dst_bytes="$(get_size_bytes DST)"
  if [[ -n "$dst_bytes" && "$dst_bytes" -lt "$src_bytes" ]]; then
    warn "destination disk ($(human_size "$dst_bytes")) is SMALLER than source ($(human_size "$src_bytes")) - the copy will be truncated"
    [[ $ASSUME_YES -eq 1 ]] || ask_yn "Continue anyway?" "n" || die "aborted"
  fi
fi

if [[ $SRC_DISK -eq 1 && $SRC_REMOTE -eq 0 ]]; then
  [[ -r "$SRC_PATH" ]] || die "cannot read $SRC_PATH - run with sudo"
fi
if [[ $DST_DISK -eq 1 ]]; then
  if [[ $DST_REMOTE -eq 0 ]]; then
    [[ -w "$DST_PATH" ]] || die "cannot write to $DST_PATH - run with sudo"
    check_mounted_local "$DST_PATH"
    confirm_disk_write "$DST_PATH (local)" "$DST_PATH"
  else
    check_mounted_remote DST
    confirm_disk_write "$DST_PATH on $DST_HOST" "$DST_PATH"
  fi
fi

if [[ $DST_DISK -eq 0 && $DST_REMOTE -eq 0 ]]; then
  mkdir -p "$(dirname "$DST_PATH")"
fi
if [[ $DST_DISK -eq 0 && $DST_REMOTE -eq 1 ]]; then
  remote_run DST "mkdir -p $(q "$(dirname "$DST_PATH")")" || true
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
