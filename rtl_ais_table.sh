#!/usr/bin/env bash

set -o pipefail
BLAU='\033[34m'        # active Class A vessels
HELLGRAU='\033[37m'    # active Class B vessels
GRAU='\033[90m'        # stale (>4 min)
WEISS='\033[37m'       # SOG value (value only)
ROTBLINK='\033[5;31m'  # LOG active
NORMAL='\033[0m'
CYAN='\033[1;36m'
ROT='\033[31m'         # Label "Ch:" fuer die Empfangskanaele

command -v rtl_ais >/dev/null || { echo "Error: rtl_ais not found."; exit 1; }
command -v python3 >/dev/null || { echo "Error: python3 not found."; exit 1; }

# AIS Standardkanaele (Default von rtl_ais, per -l/-r anpassbar falls du
# rtl_ais mit anderen Frequenzen startest)
FREQ_A_DISP="161.975"
FREQ_B_DISP="162.025"
UDP_HOST="127.0.0.1"
UDP_PORT="10110"
DEVICE_INDEX="0"

declare -A ZEIT MMSI NAME TYP KLASSE LAT LON SOG COG HDG STATUS KANAL
STALE=240        # 4 Minuten: Schiff wird grau dargestellt
# Schiffe werden nicht mehr automatisch aus der Tabelle entfernt, sie
# bleiben dauerhaft (nur grau) stehen, sobald sie einmal empfangen wurden.
RXPKS=0

LOG_FLAG="/tmp/rtl_ais_log_active"
LOG_FILE=""
rm -f "$LOG_FLAG"

FIFO="/tmp/rtl_ais_fifo_$$"
rm -f "$FIFO"
mkfifo "$FIFO"

# Read/Write-Deskriptor auf die FIFO offen halten, damit der Reader kein
# EOF bekommt, solange die Pipeline laeuft.
exec 3<>"$FIFO"

PYFILE="/tmp/ais_decode_$$.py"
ERRFILE="/tmp/rtl_ais_err_$$"
rm -f "$ERRFILE"

cat > "$PYFILE" <<'AIS_DECODE_PY'
#!/usr/bin/env python3
import sys, json

def sixbit_to_char(v):
    return chr(v + 64) if v < 32 else chr(v)

def armor_to_bits(payload):
    out = []
    for ch in payload:
        v = ord(ch) - 48
        if v > 40:
            v -= 8
        out.append(format(v, '06b'))
    return ''.join(out)

def ubits(bits, start, length):
    if length <= 0 or start + length > len(bits):
        return 0
    return int(bits[start:start+length], 2)

def sbits(bits, start, length):
    v = ubits(bits, start, length)
    if v >= (1 << (length - 1)):
        v -= (1 << length)
    return v

def sixbit_string(bits, start, length_bits):
    chars = []
    for i in range(start, start + length_bits, 6):
        if i + 6 > len(bits):
            break
        chars.append(sixbit_to_char(int(bits[i:i+6], 2)))
    return ''.join(chars).replace('@', ' ').strip()

NAVSTATUS = {
    0: 'Under way (engine)', 1: 'At anchor', 2: 'Not under command',
    3: 'Restricted manoeuvr.', 4: 'Constrained draught', 5: 'Moored',
    6: 'Aground', 7: 'Fishing', 8: 'Under way sailing', 9: 'Reserved (HSC)',
    10: 'Reserved (WIG)', 11: 'Reserved', 12: 'Reserved', 13: 'Reserved',
    14: 'AIS-SART/Distress', 15: 'Not defined',
}

def shiptype_text(code):
    try:
        c = int(code)
    except (TypeError, ValueError):
        return '-'
    if c == 0: return 'N/A'
    if 20 <= c <= 29: return 'WIG'
    if c == 30: return 'Fishing'
    if c in (31, 32): return 'Towing'
    if c == 33: return 'Dredging'
    if c == 34: return 'Diving'
    if c == 35: return 'Military'
    if c == 36: return 'Sailing'
    if c == 37: return 'Pleasure'
    if 40 <= c <= 49: return 'High-Speed'
    if c == 50: return 'Pilot'
    if c == 51: return 'SAR'
    if c == 52: return 'Tug'
    if c == 53: return 'Port Tender'
    if c == 54: return 'Anti-Pollut.'
    if c == 55: return 'Law Enforce'
    if c == 58: return 'Medical'
    if 60 <= c <= 69: return 'Passenger'
    if 70 <= c <= 79: return 'Cargo'
    if 80 <= c <= 89: return 'Tanker'
    if 90 <= c <= 99: return 'Other'
    return str(c)

INVALID_LON = 181 * 600000
INVALID_LAT = 91 * 600000

ships = {}
fragments = {}

def emit(mmsi):
    row = ships.get(mmsi)
    if row:
        sys.stdout.write(json.dumps(row) + "\n")
        sys.stdout.flush()

def process_payload(payload, channel):
    bits = armor_to_bits(payload)
    if len(bits) < 38:
        return
    msgtype = ubits(bits, 0, 6)
    mmsi = str(ubits(bits, 8, 30))
    if mmsi == '0':
        return
    row = ships.setdefault(mmsi, {
        'mmsi': mmsi, 'name': '-', 'shiptype': '-', 'cls': '-',
        'lat': '-', 'lon': '-', 'sog': '-', 'cog': '-',
        'heading': '-', 'status': '-', 'channel': '-',
    })
    if channel:
        row['channel'] = channel

    try:
        if msgtype in (1, 2, 3):
            row['cls'] = 'A'
            status = ubits(bits, 38, 4)
            row['status'] = NAVSTATUS.get(status, '-')
            sog_raw = ubits(bits, 50, 10)
            row['sog'] = f"{sog_raw/10:.1f}" if sog_raw != 1023 else '-'
            lon_raw = sbits(bits, 61, 28)
            lat_raw = sbits(bits, 89, 27)
            if lon_raw != INVALID_LON and lat_raw != INVALID_LAT:
                row['lon'] = f"{lon_raw/600000:.5f}"
                row['lat'] = f"{lat_raw/600000:.5f}"
            cog_raw = ubits(bits, 116, 12)
            row['cog'] = f"{cog_raw/10:.1f}" if cog_raw != 3600 else '-'
            hdg_raw = ubits(bits, 128, 9)
            row['heading'] = str(hdg_raw) if hdg_raw != 511 else '-'
        elif msgtype == 5:
            row['cls'] = 'A'
            name = sixbit_string(bits, 112, 120)
            if name:
                row['name'] = name
            row['shiptype'] = shiptype_text(ubits(bits, 232, 8))
        elif msgtype in (18, 19):
            row['cls'] = 'B'
            sog_raw = ubits(bits, 46, 10)
            row['sog'] = f"{sog_raw/10:.1f}" if sog_raw != 1023 else '-'
            lon_raw = sbits(bits, 57, 28)
            lat_raw = sbits(bits, 85, 27)
            if lon_raw != INVALID_LON and lat_raw != INVALID_LAT:
                row['lon'] = f"{lon_raw/600000:.5f}"
                row['lat'] = f"{lat_raw/600000:.5f}"
            cog_raw = ubits(bits, 112, 12)
            row['cog'] = f"{cog_raw/10:.1f}" if cog_raw != 3600 else '-'
            hdg_raw = ubits(bits, 124, 9)
            row['heading'] = str(hdg_raw) if hdg_raw != 511 else '-'
            if msgtype == 19:
                name = sixbit_string(bits, 143, 120)
                if name:
                    row['name'] = name
        elif msgtype == 24:
            row['cls'] = 'B'
            partno = ubits(bits, 38, 2)
            if partno == 0:
                name = sixbit_string(bits, 40, 120)
                if name:
                    row['name'] = name
            elif partno == 1:
                row['shiptype'] = shiptype_text(ubits(bits, 40, 8))
        else:
            return
    except Exception:
        return
    emit(mmsi)

def main():
    for raw in sys.stdin:
        line = raw.strip()
        if not (line.startswith('!AIVDM') or line.startswith('!AIVDO')):
            continue
        line = line.split('*', 1)[0]
        parts = line.split(',')
        if len(parts) < 6:
            continue
        try:
            total = int(parts[1])
            fragnum = int(parts[2])
        except ValueError:
            continue
        seqid = parts[3]
        channel = parts[4] or 'A'
        payload = parts[5]
        if total == 1:
            process_payload(payload, channel)
        else:
            key = (seqid, channel)
            buf = fragments.setdefault(key, {})
            buf[fragnum] = payload
            if len(buf) == total:
                full_payload = ''.join(buf[i] for i in range(1, total + 1))
                process_payload(full_payload, channel)
                del fragments[key]

if __name__ == '__main__':
    main()
AIS_DECODE_PY

cleanup() {
    if [[ -n "$PIPE_PID" ]]; then
        kill "$PIPE_PID" 2>/dev/null
        wait "$PIPE_PID" 2>/dev/null
    fi
    # Sicherstellen, dass wirklich ALLE rtl_ais/Decoder-Hintergrundprozesse
    # beendet sind
    pkill -TERM -f 'rtl_ais ' 2>/dev/null
    pkill -TERM -f "$PYFILE" 2>/dev/null
    sleep 1
    pkill -KILL -f 'rtl_ais ' 2>/dev/null
    pkill -KILL -f "$PYFILE" 2>/dev/null
    exec 3>&-
    rm -f "$FIFO" "$LOG_FLAG" "$PYFILE" "$ERRFILE"
    printf "\n\033[0mStopped.\n"
    exit 0
}
trap cleanup INT TERM

(
  while IFS= read -r -n1 -s key </dev/tty; do
    case "${key,,}" in
      l)
        if [[ -f "$LOG_FLAG" ]]; then rm -f "$LOG_FLAG"; else touch "$LOG_FLAG"; fi
        ;;
    esac
  done
) &
KEYPID=$!

# rtl_ais schreibt NMEA-Saetze (mit -n) auf stderr, Samples auf stdout.
# "2>&1 >/dev/null" leitet nur stderr weiter, stdout wird verworfen.
# tee spiegelt den Rohstream zusaetzlich in ERRFILE (fuer "Using device ..."),
# der Python-Decoder wandelt jede AIVDM/AIVDO-Zeile in eine JSON-Zeile um.
rtl_ais -n -d "$DEVICE_INDEX" -h "$UDP_HOST" -P "$UDP_PORT" 2>&1 >/dev/null \
    | tee "$ERRFILE" \
    | python3 "$PYFILE" > "$FIFO" &
PIPE_PID=$!

DEVICE="RTL-SDR"
for i in 1 2 3 4 5 6 7 8; do
    if grep -q "Using device" "$ERRFILE" 2>/dev/null; then
        DEVICE=$(grep -m1 "Using device" "$ERRFILE" | sed 's/.*Using device 0: //')
        break
    fi
    sleep 1
done

zeichne_kopf() {
    local now=$1
    local LOG_ACTIVE=0
    [[ -f "$LOG_FLAG" ]] && LOG_ACTIVE=1

    local cols right center lw rw cw gap gapfree pad1 pad2
    cols=$(tput cols 2>/dev/null || echo 80)
    local title="RTL_AIS Ship Table"
    right="$(date -d "@$now" '+%d.%m.%Y %H:%M:%S')"

    local chtxt chtxt_plain center_plain
    chtxt="${ROT}Ch:${NORMAL}${CYAN} ${FREQ_A_DISP}/${FREQ_B_DISP} MHz (A/B)"
    chtxt_plain="Ch: ${FREQ_A_DISP}/${FREQ_B_DISP} MHz (A/B)"
    center="Device: ${DEVICE}    ${chtxt}    Ships: ${#ZEIT[@]}    RXPKS: ${RXPKS}"
    center_plain="Device: ${DEVICE}    ${chtxt_plain}    Ships: ${#ZEIT[@]}    RXPKS: ${RXPKS}"

    lw=${#title}; rw=${#right}; cw=${#center_plain}
    gap=$(( cols - lw - rw ))
    gapfree=$(( gap - cw ))

    local PAD=25
    pad1=$PAD; (( pad1 < 1 )) && pad1=1
    pad2=$(( gapfree - pad1 )); (( pad2 < 1 )) && pad2=1

    printf "${CYAN}%-${lw}s${NORMAL}%${pad1}s%b%${pad2}s${CYAN}%${rw}s${NORMAL}\n" \
        "$title" "" "${CYAN}${center}${NORMAL}" "" "$right"

    local hint="Exit with Ctrl+C   (L = toggle log)"
    local status="" plain=""
    if (( LOG_ACTIVE )); then
        status="${ROTBLINK}LOG active${NORMAL}"
        plain="LOG active"
    fi
    printf "%-${#hint}s%$(( cols - ${#hint} - ${#plain} ))s${status}\n" "$hint" ""

    printf '\n'
}

zeichne() {
    local now=$1
    clear
    zeichne_kopf "$now"

    printf '%-9.9s %-10.10s %-20.20s %-12.12s %-3.3s %-9.9s %-10.10s %-6.6s %-6.6s %-4.4s %-20.20s\n' \
      "Time" "MMSI" "Name" "Type" "Cl" "Lat" "Lon" "SOG kn" "COG" "Hdg" "Status"
    printf '\n'

    for k in "${!ZEIT[@]}"; do printf '%s\t%s\n' "$k" "${ZEIT[$k]}"; done \
    | sort -t $'\t' -k2 -rn \
    | while IFS=$'\t' read -r k t; do
        alter=$(( now - t ))
        if (( alter > STALE )); then
            farbe="$GRAU"
        elif [[ "${KLASSE[$k]}" == "B" ]]; then
            farbe="$HELLGRAU"
        else
            farbe="$BLAU"
        fi
        zeit=$(date -d "@$t" +%H:%M:%S)
        printf "${farbe}%-9.9s %-10.10s %-20.20s %-12.12s %-3.3s\033[0m ${WEISS}%-9.9s %-10.10s\033[0m ${farbe}%-6.6s %-6.6s %-4.4s %-20.20s\033[0m\n" \
          "$zeit" "${MMSI[$k]}" "${NAME[$k]}" "${TYP[$k]}" "${KLASSE[$k]}" \
          "${LAT[$k]}" "${LON[$k]}" "${SOG[$k]}" "${COG[$k]}" "${HDG[$k]}" "${STATUS[$k]}"
    done
}

while :; do
    now=$(date +%s)
    rote=false

    if IFS= read -r -t 1 -u 3 json; then
        # Schutz: nur echte, gueltige JSON-Zeilen verarbeiten (falls doch mal
        # eine Nicht-JSON-Zeile im Datenstrom landet, wird sie ignoriert statt
        # die Schiffstabelle mit leeren/falschen Werten zu verfaelschen).
        result="$(python3 -c '
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
print("\t".join(str(d.get(k, "-")) for k in
    ["mmsi","name","shiptype","cls","lat","lon","sog","cog","heading","status","channel"]))
' "$json" 2>/dev/null)"
        if [[ -z "$result" ]]; then
            continue
        fi
        RXPKS=$(( RXPKS + 1 ))

        IFS=$'\t' read -r mmsi name typ klasse lat lon sog cog hdg status kanal <<< "$result"

        key="$mmsi"
        ZEIT[$key]=$now
        MMSI[$key]=$mmsi
        NAME[$key]=$name
        TYP[$key]=$typ
        KLASSE[$key]=$klasse
        LAT[$key]=$lat
        LON[$key]=$lon
        SOG[$key]=$sog
        COG[$key]=$cog
        HDG[$key]=$hdg
        STATUS[$key]=$status
        KANAL[$key]=$kanal

        if [[ -f "$LOG_FLAG" ]]; then
            if [[ -z "$LOG_FILE" ]]; then
                LOG_FILE="$(date +%Y-%m-%d-%H-%M-%S).ais.log"
                echo "# rtl_ais log started $(date '+%Y-%m-%d %H:%M:%S')" > "$LOG_FILE"
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$(date -d "@$now" +%F_%T)" "$mmsi" "$name" "$typ" "$klasse" \
                "$lat" "$lon" "$sog" "$cog" "$hdg" "$status" >> "$LOG_FILE"
        else
            LOG_FILE=""
        fi
        rote=true
    fi

    if [[ -z "${LAST_DRAW:-}" ]]; then
        rote=true
    elif (( now - LAST_DRAW >= 10 )); then
        rote=true
    fi

    if [[ "$rote" == true ]]; then
        zeichne "$now"
        LAST_DRAW="$now"
    fi
done
