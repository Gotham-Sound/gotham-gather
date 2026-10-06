#!/usr/bin/env bash
# gather-shoot — end-of-shoot media gather for the Gotham Sound Unraid server.
# Pulls media from every known source into one consolidated, device-sorted shoot
# folder, strips macOS junk, and verifies every transfer by byte count.
#
# Usage:
#   gather.sh <shoot-name> [source ...]
#     <shoot-name>   e.g. 2026-06-MWU  (rubric: YYYY-MM-CODE[-variant])
#     [source ...]   one or more of: cards zcam pix atem audio sweep
#                    plus standalone PIX drive-mode flips: pixeft | pixrec
#                    (default: all of them)
#
# Examples:
#   gather.sh 2026-06-MWU                 # full gather, all sources
#   gather.sh 2026-06-MWU cards           # just ingest whatever cards are plugged in
#   gather.sh 2026-06-MWU zcam audio      # just the Z CAM + Drive audio
#   gather.sh 2026-06-MWU sweep           # just report leftovers / unknown media
#
# Sources are READ-ONLY. Nothing is ever deleted from a card, recorder, or Drive.
# Safe to re-run: rsync resumes, already-verified files are skipped.

set -uo pipefail

# ───────────────────────── CONFIG (site-specific) ─────────────────────────
SHARE="${ISOS_SHARE:-/mnt/user/isos}"        # where shoot folders live (container sets ISOS_SHARE=/data/isos)
TMP="${TMPDIR:-/tmp}/gather-shoot.$$"        # scratch mounts
TODAY="$(date +%Y-%m-%d)"                    # used to pick "today's" media

ZCAM_HOSTS=("192.168.102.52")                # remote Z CAM(s), HTTP API on :80
ZCAM_LABEL_MAP=("192.168.102.52=TK")         # host=ISO-label -> CAM-<label>/

PIX_SUBNET="192.168.99"                      # /24 to scan for the PIX (SMB)
PIX_USER="guest"; PIX_PASS="guest"
PIX_HOST="192.168.99.192"                    # PIX HTTP+SMB host (blank = auto-discover on PIX_SUBNET)
PIX_DRIVE="1"                                # recorder bay we pull = RecordToDrive1 / share Drive_1 / HDD
PIX_RESTORE_TO_RECORD="1"                    # 1 = after copy, leave the drive in Record (staged for next shoot); 0 = leave as found
PIX_SESSION_WINDOW_HOURS="24"                # PIX drives accumulate reels from many shoots; pull only .mov files whose
                                             # mtime is within this many hours of the newest one (the current session).
PIX_PULL_ALL="0"                             # 1 = pull EVERY .mov on the drive regardless of age (old behavior)

ATEM_HOST="192.168.100.10"                   # ATEM switcher SMB
ATEM_SHARE="1003"                            # recording-disk share name
ATEM_MOUNT_OPTS="username=guest,password=,vers=3.0"   # NB: bare 'guest' fails (err 22)

RCLONE_REMOTE="gdrive"                       # rclone remote (drive.readonly)
AUDIO_FOLDER_ID="1t8Bm5MCO_I64Z3ebDugy_rciigizeB81"   # shared field-audio folder
AUDIO_MAX_AGE="${AUDIO_MAX_AGE:-72h}"        # Drive folder accumulates WAVs from many shoots; pull only ones
                                             # uploaded within this window (the current session). rclone --max-age.
AUDIO_PULL_ALL="${AUDIO_PULL_ALL:-0}"        # 1 = pull every WAV in the folder regardless of age

# Camera-card ingest source. Empty = detect+mount USB block devices (host execution).
# Set (e.g. /data/cards) = read already-mounted card dirs under it, no mounting — the
# non-privileged container path, where Unraid mounts cards and binds /mnt/disks in.
CARDS_DIR="${CARDS_DIR:-}"

# macOS / OS junk to never copy. Device metadata (.takelist.xml, .drp,
# .SD_PROJECT) is intentionally NOT excluded — we keep it.
JUNK_EXCLUDES=(--exclude='._*' --exclude='.DS_Store' --exclude='.fseventsd'
  --exclude='.Trashes' --exclude='.metadata_never_index'
  --exclude='.com.apple.timemachine.donotpresent' --exclude='.Spotlight-V100'
  --exclude='.TemporaryItems' --exclude='.fseventsd/*')

# Landing folders that "additional media" tends to sit in (for the sweep).
LANDING_DIRS=(resilio syncthing copyparty frameioupload audiotest)
# ──────────────────────────────────────────────────────────────────────────

SHOOT_NAME="${1:-}"; shift || true
[ -z "$SHOOT_NAME" ] && { echo "ERROR: pass a shoot name, e.g. $(basename "$0") 2026-06-MWU"; exit 1; }
SHOOT="$SHARE/$SHOOT_NAME"
SOURCES=("$@"); [ ${#SOURCES[@]} -eq 0 ] && SOURCES=(cards zcam pix atem audio sweep)

mkdir -p "$SHOOT" "$TMP"
trap 'for m in "$TMP"/*; do mountpoint -q "$m" 2>/dev/null && umount "$m"; done; rmdir "$TMP"/* "$TMP" 2>/dev/null' EXIT

c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_b="\033[1m"; c_0="\033[0m"
say(){ echo -e "${c_b}[$(date +%H:%M:%S)] $*${c_0}"; }
ok(){  echo -e "  ${c_g}✓${c_0} $*"; }
warn(){ echo -e "  ${c_y}⚠${c_0} $*"; }
err(){ echo -e "  ${c_r}✗${c_0} $*"; }

# verify <dest-file> <expected-bytes> ; returns 0 on match
verify(){ local got; got=$(stat -c %s "$1" 2>/dev/null || echo 0)
  if [ "$got" = "$2" ]; then ok "verified $(basename "$1") ($got bytes)"; return 0
  else err "SIZE MISMATCH $(basename "$1"): got $got, expected $2"; return 1; fi; }

human(){ awk "BEGIN{b=$1; for(u=0;b>=1024&&u<4;u++)b/=1024; printf \"%.1f%s\",b,substr(\"BKMGT\",u+1,1)}"; }

# rsync one file, resumable + junk-stripped, then verify by size.
pull_file(){ # <src> <destdir> <expected-bytes>
  local src="$1" dd="$2" exp="$3"; mkdir -p "$dd"
  rsync --inplace --partial --append-verify --no-perms --no-owner --no-group \
        "${JUNK_EXCLUDES[@]}" --info=progress2 "$src" "$dd/" || { err "rsync failed: $src"; return 1; }
  verify "$dd/$(basename "$src")" "$exp"
}

# ───────────────────────────── SOURCE: cards ─────────────────────────────
# Blackmagic .braw masters from USB card readers. A card = a USB-transport
# exfat partition (array disks are xfs/btrfs, boot is vfat, so exfat+usb is
# unambiguous here). Sort by 'CAM N' parsed from the filename.
# Ingest already-mounted card dirs (container / host-mount+bind model): no mounting,
# just read each subdir of CARDS_DIR that holds .braw. Sort by 'CAM N' same as below.
do_cards_dir(){
  say "CARDS — scanning pre-mounted card dirs under $CARDS_DIR"
  local found=0 d
  for d in "$CARDS_DIR"/*/; do
    [ -d "$d" ] || continue
    mapfile -t braws < <(find "$d" -maxdepth 3 -iname '*.braw' 2>/dev/null)
    [ ${#braws[@]} -eq 0 ] && continue
    found=1
    local label; label=$(basename "$d")
    for f in "${braws[@]}"; do
      local base cam dest exp
      base=$(basename "$f")
      cam=$(grep -oiE 'CAM[ _]*[0-9]+' <<<"$base" | grep -oE '[0-9]+' | head -1)
      dest="$SHOOT/CAM-${cam:-$label}"
      exp=$(stat -c %s "$f")
      if [ -f "$dest/$base" ] && [ "$(stat -c %s "$dest/$base" 2>/dev/null)" = "$exp" ]; then
        ok "already have $base — skipping"; continue
      fi
      say "  card '$label': $base ($(human "$exp")) -> $(basename "$dest")/"
      pull_file "$f" "$dest" "$exp"
    done
  done
  [ "$found" = 0 ] && warn "no cards with .braw found under $CARDS_DIR — plug a card into a REAR USB port (Unraid mounts it under /mnt/disks)"
}

do_cards(){
  [ -n "$CARDS_DIR" ] && [ -d "$CARDS_DIR" ] && { do_cards_dir; return; }
  say "CARDS — scanning USB readers for Blackmagic .braw cards"
  local found=0
  # Transport (usb) only appears on the whole-disk row, not on partition rows,
  # so collect USB disks first and match each exfat partition to its parent.
  local usb_disks; usb_disks=" $(lsblk -rno NAME,TRAN | awk '$2=="usb"{print $1}' | paste -sd' ') "
  while read -r name fstype pkname mp; do
    [ "$fstype" = "exfat" ] || continue
    [[ "$usb_disks" == *" $pkname "* ]] || continue
    local dev="/dev/$name" label; label=$(lsblk -rno LABEL "$dev" 2>/dev/null)
    local m="$TMP/card-$name"; mkdir -p "$m"
    mountpoint -q "$m" || mount -o ro "$dev" "$m" 2>/dev/null || { warn "could not mount $dev"; continue; }
    mapfile -t braws < <(find "$m" -maxdepth 4 -iname '*.braw' 2>/dev/null)
    [ ${#braws[@]} -eq 0 ] && { warn "card '${label:-$name}' has no .braw — skipping (sweep will note it)"; umount "$m"; continue; }
    found=1
    for f in "${braws[@]}"; do
      local base cam dest exp
      base=$(basename "$f")
      cam=$(grep -oiE 'CAM[ _]*[0-9]+' <<<"$base" | grep -oE '[0-9]+' | head -1)
      dest="$SHOOT/CAM-${cam:-${label:-$name}}"      # fallback: card label
      exp=$(stat -c %s "$f")
      say "  card '${label:-$name}': $base ($(human "$exp")) -> $(basename "$dest")/"
      pull_file "$f" "$dest" "$exp"
    done
    umount "$m" && ok "card '${label:-$name}' done — safe to remove"
  done < <(lsblk -rno NAME,FSTYPE,PKNAME,MOUNTPOINT)
  [ "$found" = 0 ] && warn "no Blackmagic cards detected. Plug into a REAR USB port (front ports are flaky) and re-run: gather.sh $SHOOT_NAME cards"
}

# ───────────────────────────── SOURCE: zcam ─────────────────────────────
# Z CAM cinema cameras over HTTP. Pull only clips whose filename timestamp is
# today. Resumable; verify against Content-Length.
do_zcam(){
  for host in "${ZCAM_HOSTS[@]}"; do
    say "ZCAM — $host"
    curl -sf -m 6 "http://$host/info" >/dev/null || { warn "$host unreachable / not a Z CAM — skipping"; continue; }
    local label="$host"; for kv in "${ZCAM_LABEL_MAP[@]}"; do [ "${kv%%=*}" = "$host" ] && label="${kv#*=}"; done
    local dest="$SHOOT/CAM-${label}"
    mapfile -t folders < <(curl -sf -m 8 "http://$host/DCIM/" | grep -oE '"[A-Z0-9]+"' | tr -d '"' | grep -v '^files$')
    local got_any=0
    for fol in "${folders[@]}"; do
      mapfile -t files < <(curl -sf -m 12 "http://$host/DCIM/$fol/" | grep -oE '"[^"]+\.(MOV|MP4|mov|mp4)"' | tr -d '"')
      for f in "${files[@]}"; do
        # filename embeds YYYYMMDD timestamp; only take today's
        local ts; ts=$(grep -oE '[0-9]{8}' <<<"$f" | head -1)
        [ "${ts:0:4}-${ts:4:2}-${ts:6:2}" = "$TODAY" ] || { warn "skip $f (not today)"; continue; }
        local exp; exp=$(curl -sf -m 10 -I "http://$host/DCIM/$fol/$f" | grep -i content-length | tr -dc '0-9')
        say "  $f ($(human "${exp:-0}")) -> CAM-${label}/"
        mkdir -p "$dest"
        curl -s --retry 5 --retry-delay 3 -C - -o "$dest/$f" "http://$host/DCIM/$fol/$f"
        verify "$dest/$f" "$exp" && got_any=1
      done
    done
    [ "$got_any" = 0 ] && warn "$host: no clips dated today"
  done
}

# ───────────────────── PIXNET control API (Sound Devices PIX) ────────────
# Unauthenticated HTTP API on port 80 (only the HTML client at / needs Digest).
# A PIX drive bay is either in "Record" mode (recorder owns it, NOT on network)
# or "Ethernet File Transfer" mode (released to SMB so we can pull). Setting:
# RecordToDrive[1-4]. Drive ids for status: 1=HDD, 2=HD2, 3=HD3, 4=HD4.
pix_find(){ # echo PIX http/smb host; PIX_HOST wins, else scan PIX_SUBNET by NetBIOS name
  if [ -n "$PIX_HOST" ]; then echo "$PIX_HOST"; return; fi
  for i in $(seq 1 254); do ( timeout 1 bash -c "echo > /dev/tcp/$PIX_SUBNET.$i/445" 2>/dev/null &&
      nmblookup -A "$PIX_SUBNET.$i" 2>/dev/null | grep -qiE 'PIX' && echo "$PIX_SUBNET.$i" ) &
      (( i % 64 == 0 )) && wait; done 2>/dev/null | head -1; wait
}
pix_json(){ grep -oE "\"$2\":\"[^\"]*\"" <<<"$1" | sed 's/.*:"//;s/"$//'; }
pix_transport(){ pix_json "$(curl -s -m 6 "http://$1/sounddevices/transport")" Transport; }
pix_mode_get(){ pix_json "$(curl -s -m 6 "http://$1/sounddevices/getsettings/RecordToDrive$2")" "RecordToDrive$2"; }
pix_drive_id(){ [ "$1" = 1 ] && echo HDD || echo "HD$1"; }
pix_mode_set(){ # host drivenum "Record"|"Ethernet File Transfer"
  curl -s -m 6 "http://$1/sounddevices/setsetting/RecordToDrive$2=$(echo "$3" | sed 's/ /%20/g')" >/dev/null; }
pix_status(){ # host drivenum -> raw OSD drive-status string (e.g. D1:Network, D1:Offline)
  pix_json "$(curl -s -m 6 "http://$1/sounddevices/invoke/RemoteApi/displayedDriveStatus(QString)/1/10,$(pix_drive_id "$2")")" String; }
# Wait for the drive's DATA share to actually appear and be READABLE, then echo
# its name. This is the reliable readiness signal — the OSD status string is NOT:
# after flipping to Ethernet File Transfer a drive may report "Network" (some
# units) OR "Offline" (others) while the share is fine. And right after the flip
# the PIX briefly advertises a "No_Drives_Attached" placeholder share before the
# real drive mounts — so we poll until a NON-placeholder Disk share both appears
# in the share list AND lists successfully. Echoes the share name on success
# (empty on timeout). Args: host / timeout-secs.
pix_data_share(){
  local t=0 s
  while [ "$t" -lt "${2:-40}" ]; do
    s=$(smbclient -L "//$1" -U "$PIX_USER%$PIX_PASS" 2>/dev/null \
        | awk '/Disk/{print $1}' | grep -viE 'No_Drives_Attached|IPC|print' | head -1)
    if [ -n "$s" ] && smbclient "//$1/$s" -U "$PIX_USER%$PIX_PASS" -c 'ls' >/dev/null 2>&1; then
      echo "$s"; return 0; fi
    sleep 2; t=$((t+2)); done; return 1; }

# Standalone source: flip the drive mode on demand.  gather.sh <shoot> pixeft | pixrec
do_pix_mode(){ # $1 = eft|record
  local host; host=$(pix_find); [ -z "$host" ] && { warn "no PIX found"; return; }
  local tr; tr=$(pix_transport "$host")
  [ "$tr" = "rec" ] && { err "PIX is RECORDING — refusing to change drive $PIX_DRIVE mode"; return; }
  if [ "$1" = eft ]; then
    say "PIX $host: drive $PIX_DRIVE -> Ethernet File Transfer"
    pix_mode_set "$host" "$PIX_DRIVE" "Ethernet File Transfer"
    local share; share=$(pix_data_share "$host" 40)
    [ -n "$share" ] \
      && ok "drive $PIX_DRIVE ready — share //$host/$share readable (status: $(pix_status "$host" "$PIX_DRIVE"))" \
      || warn "data share never came up after flip (status: $(pix_status "$host" "$PIX_DRIVE"))"
  else
    say "PIX $host: drive $PIX_DRIVE -> Record"
    pix_mode_set "$host" "$PIX_DRIVE" "Record"; sleep 3
    ok "drive $PIX_DRIVE now: $(pix_mode_get "$host" "$PIX_DRIVE")"
  fi
}

# ───────────────────────────── SOURCE: pix ──────────────────────────────
# Pull the PIX over SMB, auto-managing drive mode via PIXNET: ensure the drive
# is in Ethernet File Transfer, pull + verify, then put the mode back where it
# was (or to Record if PIX_RESTORE_TO_RECORD=1). Keep .takelist.xml; strip junk.
do_pix(){
  say "PIX — locating recorder"
  local pix; pix=$(pix_find)
  [ -z "$pix" ] && { warn "no PIX found on $PIX_SUBNET.0/24 — skipping"; return; }
  ok "PIX at $pix"
  local tr; tr=$(pix_transport "$pix")
  [ "$tr" = "rec" ] && { err "PIX is RECORDING — skipping (won't disturb a live record)"; return; }
  # Ensure Ethernet File Transfer, then wait for the real data share to be readable
  # (not a status word, not the No_Drives_Attached placeholder — see pix_data_share).
  local mode; mode=$(pix_mode_get "$pix" "$PIX_DRIVE")
  if [ "$mode" != "Ethernet File Transfer" ]; then
    say "  drive $PIX_DRIVE is '${mode:-unknown}' -> flipping to Ethernet File Transfer"
    pix_mode_set "$pix" "$PIX_DRIVE" "Ethernet File Transfer"
  fi
  local share; share=$(pix_data_share "$pix" 40)
  if [ -z "$share" ]; then
    err "drive $PIX_DRIVE data share never came up after flip (status: $(pix_status "$pix" "$PIX_DRIVE"))"; return
  fi
  ok "share //$pix/$share ready"
  local m="$TMP/pix"; mkdir -p "$m"
  local pulled=0
  if mount -t cifs "//$pix/$share" "$m" -o "username=$PIX_USER,password=$PIX_PASS,ro,vers=2.0" 2>/dev/null; then
    mkdir -p "$SHOOT/PIX"
    [ -f "$m/.takelist.xml" ] && cp -f "$m/.takelist.xml" "$SHOOT/PIX/PIX-takelist.xml" 2>/dev/null
    # Select the CURRENT session's recording(s) only. PIX drives accumulate reels
    # from multiple shoots (e.g. a prior shoot's PIX1-PIX-1-018.mov sitting next to
    # today's -019.mov). PIX .mov mtimes are real wall-clock, so pull only files
    # within PIX_SESSION_WINDOW_HOURS of the newest one; list & skip older reels.
    # PIX_PULL_ALL=1 restores the pull-everything behavior.
    local sel=() skip=() nf=0 fail=0
    if [ -n "$(find "$m" -iname 'PIX*-*.mov' -print -quit 2>/dev/null)" ]; then
      local newest cutoff
      newest=$(find "$m" -iname 'PIX*-*.mov' -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
      cutoff=$(( newest - PIX_SESSION_WINDOW_HOURS*3600 ))
      while IFS=$'\t' read -r ep pth; do
        ep=${ep%.*}
        if [ "$PIX_PULL_ALL" = 1 ] || [ "$ep" -ge "$cutoff" ]; then sel+=("$pth"); else skip+=("$pth"); fi
      done < <(find "$m" -iname 'PIX*-*.mov' -printf '%T@\t%p\n' 2>/dev/null | sort -rn)
    fi
    if [ ${#skip[@]} -gt 0 ]; then
      warn "skipping ${#skip[@]} older reel(s) from prior shoot(s) — set PIX_PULL_ALL=1 to include:"
      for s in "${skip[@]}"; do echo "      $(basename "$s")  ($(date -d "@$(stat -c %Y "$s")" +%Y-%m-%d 2>/dev/null))"; done
    fi
    [ ${#sel[@]} -eq 0 ] && warn "no current-session PIX recording found on drive"
    for f in "${sel[@]}"; do
      nf=$((nf+1))
      local exp; exp=$(stat -c %s "$f"); say "  $(basename "$f") ($(human "$exp")) -> PIX/"
      pull_file "$f" "$SHOOT/PIX" "$exp" || fail=1
    done
    umount "$m"
    [ "$nf" -gt 0 ] && [ "$fail" -eq 0 ] && pulled=1
  else err "could not mount //$pix/$share"; fi
  # Restore drive mode. Default leaves it as we found it; with PIX_RESTORE_TO_RECORD=1
  # stage to Record — but ONLY after a fully-verified copy, so a failed pull stays in
  # Ethernet File Transfer and can be retried without re-flipping.
  local target="$mode"
  [ "$PIX_RESTORE_TO_RECORD" = 1 ] && [ "$pulled" -eq 1 ] && target="Record"
  [ "$pulled" -eq 1 ] || warn "PIX copy did not fully verify — leaving drive $PIX_DRIVE in its current mode for retry"
  if [ -n "$target" ] && [ "$target" != "Ethernet File Transfer" ]; then
    say "  setting drive $PIX_DRIVE -> $target"
    pix_mode_set "$pix" "$PIX_DRIVE" "$target"
    ok "drive $PIX_DRIVE now: $(pix_mode_get "$pix" "$PIX_DRIVE")"
  fi
}

# ───────────────────────────── SOURCE: atem ─────────────────────────────
# ATEM switcher multicam ISO recording (a DaVinci Resolve project) over SMB.
# Pick today's project folder; preserve its named folder so the .drp relinks.
do_atem(){
  say "ATEM — $ATEM_HOST/$ATEM_SHARE"
  local m="$TMP/atem"; mkdir -p "$m"
  mount -t cifs "//$ATEM_HOST/$ATEM_SHARE" "$m" -o "$ATEM_MOUNT_OPTS,ro" 2>/dev/null ||
    { err "could not mount ATEM (try adjusting ATEM_MOUNT_OPTS)"; return; }
  # newest project folder modified today
  local proj
  proj=$(find "$m" -maxdepth 1 -mindepth 1 -type d -newermt "$TODAY 00:00" -printf '%T@ %p\n' 2>/dev/null \
         | sort -rn | head -1 | cut -d' ' -f2-)
  [ -z "$proj" ] && { warn "no ATEM project folder dated today — skipping"; umount "$m"; return; }
  local name; name=$(basename "$proj")
  say "  today's project: $name -> ATEM/$name/"
  local exp; exp=$(find "$proj" -type f ! -name '._*' ! -name '.DS_Store' -printf '%s\n' | awk '{s+=$1}END{print s}')
  rsync -rt --inplace --partial --append-verify --no-perms --no-owner --no-group \
        "${JUNK_EXCLUDES[@]}" --info=progress2 "$proj" "$SHOOT/ATEM/"
  local got; got=$(find "$SHOOT/ATEM/$name" -type f -printf '%s\n' | awk '{s+=$1}END{print s}')
  [ "$got" = "$exp" ] && ok "verified ATEM/$name ($got bytes, junk stripped)" || err "ATEM size mismatch: got $got expected $exp"
  umount "$m"
}

# ───────────────────────────── SOURCE: audio ────────────────────────────
# Field audio (MixPre WAV) that the remote talent uploads to Google Drive.
do_audio(){
  say "AUDIO — Google Drive folder $AUDIO_FOLDER_ID via rclone:$RCLONE_REMOTE"
  rclone lsf "$RCLONE_REMOTE:" --drive-root-folder-id "$AUDIO_FOLDER_ID" >/dev/null 2>&1 ||
    { warn "rclone remote '$RCLONE_REMOTE' not working — run: rclone authorize \"drive\" --drive-scope=drive.readonly, then add token to $(rclone config file|tail -1)"; return; }
  # The Drive folder accumulates WAVs from many shoots. Pull only the current session's
  # (uploaded within AUDIO_MAX_AGE) unless AUDIO_PULL_ALL=1 — mirrors the PIX session window.
  local age=(); [ "$AUDIO_PULL_ALL" != 1 ] && age=(--max-age "$AUDIO_MAX_AGE")
  local recent; recent=$(rclone lsf "$RCLONE_REMOTE:" --drive-root-folder-id "$AUDIO_FOLDER_ID" \
      --include '*.WAV' --include '*.wav' "${age[@]}" 2>/dev/null)
  if [ -z "$recent" ]; then
    if [ "$AUDIO_PULL_ALL" = 1 ]; then warn "no WAVs in the Drive folder"; else
      warn "no audio uploaded in the last $AUDIO_MAX_AGE — nothing to pull (set AUDIO_PULL_ALL=1 to include older files)"; fi
    return
  fi
  say "  pulling: $(echo "$recent" | tr '\n' ' ')"
  mkdir -p "$SHOOT/AUDIO"
  rclone copy "$RCLONE_REMOTE:" "$SHOOT/AUDIO/" --drive-root-folder-id "$AUDIO_FOLDER_ID" \
    --include '*.WAV' --include '*.wav' "${age[@]}" --transfers 2 --stats 5s --stats-one-line --progress
  if rclone check "$RCLONE_REMOTE:" "$SHOOT/AUDIO/" --drive-root-folder-id "$AUDIO_FOLDER_ID" \
       --include '*.WAV' --include '*.wav' "${age[@]}" 2>&1 | grep -q '0 differences found'; then
    ok "verified AUDIO (rclone hash check, 0 differences)"
  else warn "AUDIO rclone check reported differences — inspect manually"; fi
}

# ───────────────────────────── SOURCE: sweep ────────────────────────────
# Report "additional media" we don't auto-handle, so nothing is silently missed.
do_sweep(){
  say "SWEEP — looking for additional / unrecognized media"
  # USB disks present but not ingested as cards
  while read -r name fstype tran mp; do
    [ "$tran" = "usb" ] && [ -n "$fstype" ] && [ "$fstype" != "exfat" ] && [ "$name" != "sda1" ] &&
      warn "USB disk /dev/$name ($fstype) present — not a standard card; check it"
  done < <(lsblk -rno NAME,FSTYPE,TRAN,MOUNTPOINT)
  # files freshly dropped into landing folders
  for d in "${LANDING_DIRS[@]}"; do
    [ -d "$SHARE/$d" ] || continue
    local hits; hits=$(find "$SHARE/$d" -type f -newermt "$TODAY 00:00" \
        ! -name '.DS_Store' ! -name '._*' -printf '%s\t%p\n' 2>/dev/null)
    [ -n "$hits" ] && { warn "fresh files in $d/ (may need manual gather):"; echo "$hits" | while IFS=$'\t' read -r s p; do echo "      $(human "$s")  ${p#$SHARE/}"; done; }
  done
  ok "sweep done — review any ⚠ above"
}

# ──────────────────────────────── RUN ───────────────────────────────────
say "GATHER → $SHOOT   sources: ${SOURCES[*]}"
for s in "${SOURCES[@]}"; do case "$s" in
  cards) do_cards;; zcam) do_zcam;; pix) do_pix;; atem) do_atem;; audio) do_audio;; sweep) do_sweep;;
  pixeft) do_pix_mode eft;; pixrec) do_pix_mode record;;
  *) warn "unknown source '$s'";; esac; done

say "MANIFEST — $SHOOT"
find "$SHOOT" -mindepth 1 -maxdepth 1 -type d | sort | while read -r d; do
  n=$(find "$d" -type f ! -name '._*' ! -name '.DS_Store' | wc -l)
  b=$(find "$d" -type f ! -name '._*' ! -name '.DS_Store' -printf '%s\n' | awk '{s+=$1}END{print s+0}')
  printf "  %-22s %3s files  %8s\n" "$(basename "$d")/" "$n" "$(human "$b")"
done
say "done."
