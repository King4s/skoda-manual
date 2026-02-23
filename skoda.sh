#!/bin/bash
set -e
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────
MANUAL=""
LANGUAGE="en_GB"
DO_HTML=false
DO_PDF=false
STANDALONE=false
LIST_MANUALS=false
CLEAR_CACHE=false
INTERACTIVE=false
TOC_CONTENT=""
TOC=true
CURRENT_SECTION=0
TOTAL_SECTIONS=0
MAXSECT=100
ACTIVATE_DELAY=false
PDF_RENDERER=""
REFERER="https://digital-manual.skoda-auto.com/"
AUTO_COOKIE=true
COOKIE_FILE="${COOKIE_FILE:-}"

# ─── Load .env if present ─────────────────────────────────────────────────────
if [ -f ".env" ]; then
    set -a; source .env; set +a
fi

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --html)        DO_HTML=true;       shift ;;
        --pdf)         DO_PDF=true;        shift ;;
        --standalone)  STANDALONE=true;    shift ;;
        --list)        LIST_MANUALS=true;  shift ;;
        --clear-cache) CLEAR_CACHE=true;   shift ;;
        --auto-cookie) AUTO_COOKIE=true;   shift ;;
        --no-auto-cookie) AUTO_COOKIE=false; shift ;;
        --cookie-file)
            if [ -z "${2:-}" ]; then
                >&2 echo "ERROR: --cookie-file requires a path."
                exit 1
            fi
            COOKIE_FILE="$2"
            shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: $(basename "$0") [OPTIONS] [MANUAL_ID] [LANGUAGE]

  Run without arguments for interactive mode.

Options:
  --html          Generate HTML output (default if no format specified)
  --pdf           Generate PDF output (requires chromium, wkhtmltopdf, or weasyprint)
  --standalone    Embed all assets in HTML (single self-contained file)
  --list          List available manuals for LANGUAGE (default: en_GB)
  --clear-cache   Delete ./cache/ and ./images/
  --auto-cookie   Try to auto-load cookies from browser/cookie file (default)
  --no-auto-cookie  Disable auto cookie discovery
  --cookie-file   Read cookies from Netscape cookie file
  --help          Show this help

Authentication — set in .env file or environment:
  AUTO cookie discovery is enabled by default.
  COOKIES         Browser session cookies (recommended)
  COOKIE_FILE     Netscape cookie file path (optional)

.env file example:
  COOKIES=JSESSIONID=...; BIGip...=...
  COOKIE_FILE=./skoda_cookies.txt

Examples:
  $(basename "$0")
  $(basename "$0") --list da_DK
  $(basename "$0") b6c0b6d20c1b2988ac1445253a0f2c00_3_da_DK da_DK --html
  $(basename "$0") b6c0b6d20c1b2988ac1445253a0f2c00_3_da_DK da_DK --html --pdf
  $(basename "$0") b6c0b6d20c1b2988ac1445253a0f2c00_3_da_DK da_DK --standalone
  $(basename "$0") --clear-cache
EOF
            exit 0 ;;
        --*)
            >&2 echo "ERROR: Unknown option: $1"
            >&2 echo "Run '$(basename "$0") --help' for usage."
            exit 1 ;;
        *)
            [ -z "$MANUAL" ] && MANUAL="$1" || LANGUAGE="$1"
            shift ;;
    esac
done

# Determine mode
if [ -z "$MANUAL" ] && ! $LIST_MANUALS && ! $CLEAR_CACHE; then
    INTERACTIVE=true
fi

# Default to HTML in non-interactive flag mode
if ! $INTERACTIVE && ! $DO_HTML && ! $DO_PDF; then
    DO_HTML=true
fi

# ─── Clear cache ──────────────────────────────────────────────────────────────
if $CLEAR_CACHE; then
    >&2 echo "Clearing cache (./cache/ and ./images/)..."
    rm -rf ./cache ./images
    >&2 echo "Done."
    exit 0
fi

# ─── Dependency check ─────────────────────────────────────────────────────────
for cmd in curl jq xmllint shuf base64 python3; do
    if ! command -v "$cmd" &>/dev/null; then
        >&2 echo "ERROR: Required command not found: $cmd"
        >&2 echo "Install: sudo apt install curl jq libxml2-utils coreutils python3"
        exit 1
    fi
done

# Detect PDF renderer (always, so interactive mode can show availability)
for cmd in chromium chromium-browser google-chrome google-chrome-stable wkhtmltopdf weasyprint; do
    if command -v "$cmd" &>/dev/null; then
        PDF_RENDERER="$cmd"
        break
    fi
done

# Fail fast if --pdf requested but no renderer
if $DO_PDF && [ -z "$PDF_RENDERER" ]; then
    >&2 echo "ERROR: No PDF renderer found. Install one of:"
    >&2 echo "  sudo apt install chromium      (best quality)"
    >&2 echo "  sudo apt install wkhtmltopdf   (alternative)"
    >&2 echo "  pip install weasyprint         (alternative)"
    exit 1
fi

mkdir -p ./images ./cache

# ─── HTTP helpers ─────────────────────────────────────────────────────────────
function normalizeCookieHeader() {
    local RAW=$1
    RAW="${RAW#Cookie: }"
    RAW="${RAW#cookie: }"
    RAW="$(echo "$RAW" | tr '\r\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]*;[[:space:]]*/; /g')"
    echo "$RAW"
}

function testSessionCookies() {
    local TEST_LANG="${1:-${LANGUAGE:-en_GB}}"
    local TEST_REFERER="https://digital-manual.skoda-auto.com/w/${TEST_LANG}/"
    local TEST_URL="https://digital-manual.skoda-auto.com/api/web/V6/search?query=&facetfilters=topic-type_%7C_welcome&lang=${TEST_LANG}&page=0&pageSize=1"
    local TMP_BODY
    TMP_BODY="$(mktemp)"

    local STATUS
    STATUS="$(curl -sS --compressed -o "$TMP_BODY" -w '%{http_code}' \
        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0' \
        -H 'Accept: application/json, text/plain, */*' \
        -H 'Accept-Language: en-US,en;q=0.5' \
        -H "Referer: ${TEST_REFERER}" \
        -H "Cookie: ${COOKIES}" \
        "${TEST_URL}" || true)"

    if [ "$STATUS" = "200" ] && jq -e '.results' "$TMP_BODY" >/dev/null 2>&1; then
        rm -f "$TMP_BODY"
        return 0
    fi

    rm -f "$TMP_BODY"
    return 1
}

function cookiesFromNetscapeFile() {
    local FILE=$1
    [ -f "$FILE" ] || return 1
    python3 - "$FILE" <<'PY'
import sys
from collections import OrderedDict

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="ignore") as f:
    lines = f.read().splitlines()

cookies = OrderedDict()
for line in reversed(lines):
    if not line.strip():
        continue
    raw = line
    if raw.startswith("#HttpOnly_"):
        raw = raw[len("#HttpOnly_"):]
    elif raw.startswith("#"):
        continue

    parts = raw.split("\t")
    if len(parts) < 7:
        continue
    domain, _, _, _, _, name, value = parts[:7]
    if "digital-manual.skoda-auto.com" not in domain:
        continue
    if name and value and name not in cookies:
        cookies[name] = value

order = [
    "JSESSIONID",
    "BIGipServerP_SMBSTAP.app~P_SMBSTAP_pool",
    "TS01e91aa3",
    "cb-enabled",
]
keys = [k for k in order if k in cookies] + [k for k in cookies.keys() if k not in order]
print("; ".join(f"{k}={cookies[k]}" for k in keys))
PY
}

function cookiesFromFirefoxProfile() {
    [ -d "$HOME/.mozilla/firefox" ] || return 1

    while IFS= read -r DB; do
        [ -f "$DB" ] || continue
        local C
C="$(python3 - "$DB" <<'PY'
import os
import shutil
import sqlite3
import sys
import tempfile
from collections import OrderedDict

db_src = sys.argv[1]
fd, db_tmp = tempfile.mkstemp(prefix="skoda_ff_", suffix=".sqlite")
os.close(fd)
try:
    shutil.copy2(db_src, db_tmp)
    con = sqlite3.connect(db_tmp)
    cur = con.cursor()
    rows = cur.execute(
        """
        SELECT name, value, host, lastAccessed
        FROM moz_cookies
        WHERE host LIKE '%digital-manual.skoda-auto.com'
        ORDER BY lastAccessed DESC
        """
    ).fetchall()
finally:
    try:
        con.close()
    except Exception:
        pass
    try:
        os.unlink(db_tmp)
    except Exception:
        pass

cookies = OrderedDict()
for name, value, host, _ in rows:
    if not name or not value:
        continue
    if name not in cookies:
        cookies[name] = value

order = [
    "JSESSIONID",
    "BIGipServerP_SMBSTAP.app~P_SMBSTAP_pool",
    "TS01e91aa3",
    "cb-enabled",
]
keys = [k for k in order if k in cookies] + [k for k in cookies.keys() if k not in order]
print("; ".join(f"{k}={cookies[k]}" for k in keys))
PY
)" || true
        C="${C:-}"
        C="$(normalizeCookieHeader "$C")"
        if [ -n "$C" ]; then
            echo "$C"
            return 0
        fi
    done < <(find "$HOME/.mozilla/firefox" -maxdepth 3 -type f -name "cookies.sqlite" 2>/dev/null | sort -r)

    return 1
}

function cookiesFromChromiumProfile() {
    local ROOT
    for ROOT in "$HOME/.config/google-chrome" "$HOME/.config/chromium" "$HOME/.config/BraveSoftware/Brave-Browser"; do
        [ -d "$ROOT" ] || continue
        while IFS= read -r DB; do
            [ -f "$DB" ] || continue
            local C
            C="$(python3 - "$DB" <<'PY'
import os
import shutil
import sqlite3
import sys
import tempfile
from collections import OrderedDict

db_src = sys.argv[1]
fd, db_tmp = tempfile.mkstemp(prefix="skoda_ch_", suffix=".sqlite")
os.close(fd)
try:
    shutil.copy2(db_src, db_tmp)
    con = sqlite3.connect(db_tmp)
    cur = con.cursor()
    rows = cur.execute(
        """
        SELECT name, value, host_key, last_access_utc
        FROM cookies
        WHERE host_key LIKE '%digital-manual.skoda-auto.com%'
        ORDER BY last_access_utc DESC
        """
    ).fetchall()
finally:
    try:
        con.close()
    except Exception:
        pass
    try:
        os.unlink(db_tmp)
    except Exception:
        pass

cookies = OrderedDict()
for name, value, host, _ in rows:
    if not name or not value:
        continue
    if name not in cookies:
        cookies[name] = value

order = [
    "JSESSIONID",
    "BIGipServerP_SMBSTAP.app~P_SMBSTAP_pool",
    "TS01e91aa3",
    "cb-enabled",
]
keys = [k for k in order if k in cookies] + [k for k in cookies.keys() if k not in order]
print("; ".join(f"{k}={cookies[k]}" for k in keys))
PY
)" || true
            C="${C:-}"
            C="$(normalizeCookieHeader "$C")"
            if [ -n "$C" ]; then
                echo "$C"
                return 0
            fi
        done < <(find "$ROOT" -maxdepth 3 -type f -name "Cookies" 2>/dev/null | sort -r)
    done

    return 1
}

function tryCookieCandidate() {
    local SOURCE=$1
    local CANDIDATE=$2

    CANDIDATE="$(normalizeCookieHeader "$CANDIDATE")"
    [ -n "$CANDIDATE" ] || return 1

    COOKIES="$CANDIDATE"
    if testSessionCookies "$LANGUAGE"; then
        >&2 echo "Auto cookie source: ${SOURCE}"
        return 0
    fi

    COOKIES=""
    return 1
}

function autoLoadCookies() {
    [ -n "$COOKIES" ] && return 0
    $AUTO_COOKIE || return 1

    >&2 echo "Trying automatic cookie discovery..."

    local CANDIDATE

    if [ -n "$COOKIE_FILE" ] && [ -f "$COOKIE_FILE" ]; then
        CANDIDATE="$(cookiesFromNetscapeFile "$COOKIE_FILE" 2>/dev/null || true)"
        if tryCookieCandidate "cookie file: ${COOKIE_FILE}" "$CANDIDATE"; then
            return 0
        fi
    fi

    local AUTO_COOKIE_FILES=("./skoda_cookies.txt" "/tmp/skoda_cookies.txt" "/tmp/skoda_c.txt" "../../tmp/skoda_cookies.txt" "../../tmp/skoda_c.txt")
    local FILE
    for FILE in "${AUTO_COOKIE_FILES[@]}"; do
        [ -f "$FILE" ] || continue
        CANDIDATE="$(cookiesFromNetscapeFile "$FILE" 2>/dev/null || true)"
        if tryCookieCandidate "cookie file: ${FILE}" "$CANDIDATE"; then
            return 0
        fi
    done

    CANDIDATE="$(cookiesFromFirefoxProfile 2>/dev/null || true)"
    if tryCookieCandidate "Firefox profile" "$CANDIDATE"; then
        return 0
    fi

    CANDIDATE="$(cookiesFromChromiumProfile 2>/dev/null || true)"
    if tryCookieCandidate "Chromium profile" "$CANDIDATE"; then
        return 0
    fi

    return 1
}

function fetchFile() {
    local URL=$1
    local DESTINATION=$2
    local RETRY=${3:-0}

    if [ "${RETRY}" -ge 5 ]; then
        >&2 echo "ERROR: Failed to fetch ${DESTINATION} after 5 retries. Aborting."
        exit 1
    fi

    if [ ! -s "${DESTINATION}" ]; then
        >&2 echo "Fetching ${DESTINATION}"
        rm -f "${DESTINATION}"
        curl "${URL}" --retry 10 --retry-all-errors --compressed \
            -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0' \
            -H 'Accept: application/json, text/plain, */*' \
            -H 'Accept-Language: en-US,en;q=0.5' \
            -H 'Accept-Encoding: gzip, deflate, br' \
            -H 'Connection: keep-alive' \
            -H "Referer: $REFERER" \
            -H "Cookie: $COOKIES" \
            -H 'Sec-Fetch-Dest: empty' \
            -H 'Sec-Fetch-Mode: cors' \
            -H 'Sec-Fetch-Site: same-origin' \
            > "${DESTINATION}"
        ACTIVATE_DELAY=true
    else
        >&2 echo "  [cache] ${DESTINATION}"
    fi

    if grep -q "An Authentication object was not found in the SecurityContext" "${DESTINATION}" 2>/dev/null; then
        rm -f "${DESTINATION}"
        >&2 echo "Session expired."
        >&2 echo "WARNING: Refresh COOKIES and rerun."
        sleep $(shuf -i 1-5 -n 1)
        fetchFile "$URL" "${DESTINATION}" $(( RETRY + 1 ))
    fi
}

function grabImage() {
    local IMG=$1
    local DEST_PATH=$2
    local RETRY=${3:-0}

    if [ -z "${IMG}" ] || [ "${IMG}" = "null" ]; then return 0; fi
    if [ "${RETRY}" -ge 5 ]; then
        >&2 echo "WARNING: Failed to fetch image ${IMG} after 5 retries. Skipping."
        return 0
    fi

    local DESTINATION="${DEST_PATH}/${IMG}"

    if [ -s "${DESTINATION}" ]; then
        if grep -q "An Authentication object was not found in the SecurityContext" "${DESTINATION}" 2>/dev/null; then
            rm -f "${DESTINATION}"
        else
            >&2 echo "  [cache] image: ${IMG}"
            return 0
        fi
    fi

    >&2 echo "  Fetching image: ${IMG}"
    rm -f "${DESTINATION}"
    curl "https://digital-manual.skoda-auto.com/public/media?lang=${LANGUAGE}&key=${IMG}" \
        --retry 10 --retry-all-errors \
        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0' \
        -H 'Accept: image/avif,image/webp,*/*' \
        -H 'Accept-Language: en-US,en;q=0.5' \
        -H "Referer: $REFERER" \
        -H "Cookie: $COOKIES" \
        -H 'Sec-Fetch-Dest: image' \
        -H 'Sec-Fetch-Mode: no-cors' \
        -H 'Sec-Fetch-Site: same-origin' \
        -H 'Pragma: no-cache' \
        -H 'Cache-Control: no-cache' \
        > "${DESTINATION}"
    ACTIVATE_DELAY=true

    if grep -q "An Authentication object was not found in the SecurityContext" "${DESTINATION}" 2>/dev/null; then
        rm -f "${DESTINATION}"
        >&2 echo "Session expired (image)."
        sleep $(shuf -i 1-5 -n 1)
        grabImage "$IMG" "$DEST_PATH" $(( RETRY + 1 ))
    fi
}

# ─── HTML helpers ─────────────────────────────────────────────────────────────
function sectionId() {
    local LINK=$1 LABEL=$2
    if [ -n "$LINK" ] && [ "$LINK" != "null" ]; then
        echo "$LINK"
    else
        echo "$LABEL" | base64 -w 0 | tr '+/=' '-_~'
    fi
}

function handleSectionContent2Html() {
    local JSONPATH=$1 HTMLPATH=$2
    local HTMLBODY
    HTMLBODY="$(jq -r ".bodyHtml" "${JSONPATH}")"
    local LINK_STATE_KEYS
    LINK_STATE_KEYS="$(jq -r ".linkState | keys[]" "${JSONPATH}")"

    for KEY in ${LINK_STATE_KEYS[@]}; do
        >&2 echo "  Replacing link: ${KEY}"
        local ANCHOR_TO_REPLACE
        ANCHOR_TO_REPLACE="$(echo "$HTMLBODY" | xmllint --xpath "//html//a[@id='"${KEY}"']" -)"
        local LINK_TYPE
        LINK_TYPE="$(jq -r ".linkState[] | select(.id==\"${KEY}\") | .linkType" "${JSONPATH}")"
        local ANCHOR_MODIFIED
        if [ "$LINK_TYPE" == "dynamic" ]; then
            local TARGET
            TARGET="$(jq -r ".linkState[] | select(.id==\"${KEY}\") | .target" "${JSONPATH}")"
            ANCHOR_MODIFIED="$(echo "$ANCHOR_TO_REPLACE" | sed 's|href="#"|href="#'"${TARGET}"'"|g')"
        else
            ANCHOR_MODIFIED="$(echo "$ANCHOR_TO_REPLACE" | sed -E 's|href=\"([^.]*)\.html#([^\"]*)\"|href=\"#\1\"|')"
        fi
        HTMLBODY="${HTMLBODY/"$ANCHOR_TO_REPLACE"/"$ANCHOR_MODIFIED"}"
    done

    echo "$HTMLBODY" > "${HTMLPATH}"
    echo "$HTMLBODY" \
        | sed 's|<?[-A-Za-z0-9 "=\.]*?>||g' \
        | sed 's|<!DOCTYPE.*||g' \
        | sed 's|^  PUBLIC ".*||g' \
        | sed 's|<html[0-9"= a-z\-]*>||g' \
        | sed 's|</html>||g' \
        | sed 's/data-src="https:\/\/digital-manual.skoda-auto.com\/default\/public\/media?lang='"${LANGUAGE}"'&amp;key=/src="images\//g'
}

function handleSection() {
    local CURRENTPATH=$1 EXPR=$2
    local LABEL
    LABEL="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.label" | sed 's|<[^>]*>||g' | sed 's|\/|, |g')"
    local CHILDREN
    CHILDREN="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.children | length")"
    local LINK
    LINK=$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.linkTarget")
    local ID
    ID=$(sectionId "$LINK" "$LABEL")

    [ -n "$ID" ] && [ "$ID" != "null" ] \
        && echo "<div class='section' id='${ID}'>" \
        || echo "<div class='section'>"
    echo "<div class='section-label'>${LABEL^}</div>"

    local WORKINGPATH="${CURRENTPATH}/${LABEL}"
    mkdir -p "${WORKINGPATH}"

    if [ -n "$LINK" ] && [ "$LINK" != "null" ]; then
        CURRENT_SECTION=$(( CURRENT_SECTION + 1 ))
        >&2 echo "[${CURRENT_SECTION}/${TOTAL_SECTIONS}] ${LABEL}"

        local CURRENT_PAGE_JSON="${WORKINGPATH}/${LABEL}.json"
        local CURRENT_PAGE_HTML="${CURRENT_PAGE_JSON}.html"

        fetchFile "https://digital-manual.skoda-auto.com/api/vw-topic/V1/topic?key=${LINK}&displaytype=desktop&language=${LANGUAGE}" "${CURRENT_PAGE_JSON}"
        handleSectionContent2Html "${CURRENT_PAGE_JSON}" "${CURRENT_PAGE_HTML}"

        while read IMG; do
            grabImage "$IMG" "./images"
        done < <(xmllint --xpath "//html//img/@data-src" "${CURRENT_PAGE_HTML}" 2>/dev/null \
            | sed 's/ data-src="https:\/\/digital-manual.skoda-auto.com\/default\/public\/media?lang='"${LANGUAGE}"'&amp;key=\(.*\)"/\1/g' \
            | sed 's/&amp;/\&/g')
    fi

    local i TOP
    TOP=$(( CHILDREN > MAXSECT ? MAXSECT : CHILDREN ))
    for ((i=0; i<TOP; i++)); do
        if [ "$ACTIVATE_DELAY" = true ]; then
            >&2 echo "Pausing before next section..."
            sleep $(shuf -i 5-15 -n 1)
            ACTIVATE_DELAY=false
        fi
        handleSection "${WORKINGPATH}" "$EXPR.children[${i}]"
    done
    echo "</div>"
}

function handleTocItem() {
    local EXPR=$1
    local LABEL
    LABEL="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.label" | sed 's|<[^>]*>||g' | sed 's|\/|, |g')"
    local CHILDREN
    CHILDREN="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.children | length")"
    local LINK
    LINK=$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.linkTarget")
    local ID
    ID=$(sectionId "$LINK" "$LABEL")

    echo "<li><a href='#${ID}'>${LABEL^}</a>"
    local i TOP
    TOP=$(( CHILDREN > MAXSECT ? MAXSECT : CHILDREN ))
    echo '<ol>'
    for ((i=0; i<TOP; i++)); do handleTocItem "$EXPR.children[${i}]"; done
    echo '</ol>'
    echo '</li>'
}

function handleToc() {
    local EXPR=$1
    local LABEL
    LABEL="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.label" | sed 's|<[^>]*>||g' | sed 's|\/|, |g')"
    local CHILDREN
    CHILDREN="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.children | length")"
    local i TOP
    TOP=$(( CHILDREN > MAXSECT ? MAXSECT : CHILDREN ))

    >&2 echo "Generating table of contents..."
    echo '<nav id="toc" aria-labelledby="toc-label">'
    echo "<h2 id=\"toc-label\">${LABEL}</h2>"
    echo '<ol>'
    for ((i=0; i<TOP; i++)); do handleTocItem "$EXPR.children[${i}]"; done
    echo '</ol>'
    echo '</nav>'
}

function handleCover() {
    local MANUAL_LIST_PATH=$1
    local COVER_IMAGE COVER_ABSTRACT COVER_PART
    COVER_IMAGE="$(jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .previewImage" "${MANUAL_LIST_PATH}")"
    COVER_ABSTRACT="$(jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .abstractText" "${MANUAL_LIST_PATH}")"
    COVER_PART="$(jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .facets[0].\"1\"[0]" "${MANUAL_LIST_PATH}")"

    echo '<div class="panel panel-default">'
    echo '<div class="panel-heading">'
    echo '<img class="content blockimage" src="./images/'"${COVER_IMAGE}"'" alt="Card image">'
    echo '</div><div class="panel-body">'
    echo '<h1 class="card-title">'"${COVER_ABSTRACT}"'</h1>'
    echo "${COVER_PART}"
    echo '</div></div>'
}

# ─── Output helpers ───────────────────────────────────────────────────────────
function makeStandalone() {
    local HTML_IN=$1 HTML_OUT=$2
    >&2 echo "Embedding assets into standalone HTML..."
    python3 - "$HTML_IN" "$HTML_OUT" <<'PYEOF'
import sys, re, base64, os

html_in, html_out = sys.argv[1], sys.argv[2]
html_dir = os.path.dirname(os.path.abspath(html_in))

with open(html_in, 'r', encoding='utf-8') as f:
    content = f.read()

def detect_mime(path):
    with open(path, 'rb') as f:
        h = f.read(16)
    if h[:8] == b'\x89PNG\r\n\x1a\n': return 'image/png'
    if h[:3] == b'\xff\xd8\xff':      return 'image/jpeg'
    if h[:4] == b'GIF8':              return 'image/gif'
    if h[:4] == b'RIFF' and h[8:12] == b'WEBP': return 'image/webp'
    if b'ftyp' in h:
        return 'image/avif' if (b'avif' in h or b'avis' in h) else 'image/heif'
    try:
        s = h.decode('utf-8', errors='ignore')
        if '<svg' in s or '<?xml' in s: return 'image/svg+xml'
    except Exception:
        pass
    return 'application/octet-stream'

def inline_css(m):
    path = os.path.join(html_dir, m.group(1))
    if os.path.isfile(path):
        with open(path, 'r', encoding='utf-8') as f:
            return f'<style>\n{f.read()}\n</style>'
    return m.group(0)

def inline_img(m):
    path = os.path.join(html_dir, m.group(1))
    if not os.path.isfile(path):
        return m.group(0)
    try:
        mime = detect_mime(path)
        with open(path, 'rb') as f:
            data = base64.b64encode(f.read()).decode()
        return f'src="data:{mime};base64,{data}"'
    except Exception as e:
        print(f'  Warning: could not embed {path}: {e}', file=sys.stderr)
        return m.group(0)

content = re.sub(r'<link[^>]+href="([^"]+\.css)"[^>]*/>', inline_css, content)
content = re.sub(r'src="(images/[^"]+)"', inline_img, content)

with open(html_out, 'w', encoding='utf-8') as f:
    f.write(content)

size_mb = os.path.getsize(html_out) / 1024 / 1024
print(f'Standalone HTML written ({size_mb:.1f} MB)', file=sys.stderr)
PYEOF
}

function makePdf() {
    local HTML_FILE=$1 PDF_FILE=$2
    local ABS_HTML ABS_PDF
    ABS_HTML="$(realpath "$HTML_FILE")"
    ABS_PDF="$(realpath "$PDF_FILE")"
    >&2 echo "Generating PDF with ${PDF_RENDERER}..."
    case "$PDF_RENDERER" in
        chromium*|google-chrome*)
            "$PDF_RENDERER" \
                --headless --disable-gpu --no-sandbox --disable-dev-shm-usage \
                --print-to-pdf="${ABS_PDF}" --no-pdf-header-footer \
                "file://${ABS_HTML}" 2>/dev/null ;;
        wkhtmltopdf)
            wkhtmltopdf --enable-local-file-access --no-stop-slow-scripts \
                --quiet "${ABS_HTML}" "${ABS_PDF}" 2>/dev/null ;;
        weasyprint)
            weasyprint "${ABS_HTML}" "${ABS_PDF}" 2>/dev/null ;;
    esac
    >&2 echo "PDF written ($(du -sh "$ABS_PDF" | cut -f1))"
}

function sanitizeFileComponent() {
    local RAW=$1
    RAW="$(echo "$RAW" | tr '\r\n\t' '   ' | sed -E 's/[\/\\:*?"<>|()]+/_/g; s/[[:space:]]+/_/g; s/_+/_/g; s/^_+//; s/_+$//')"
    [ -z "$RAW" ] && RAW="manual"
    echo "$RAW"
}

function generateHtml() {
    local MANUAL_LIST_PATH=$1
    echo "<!DOCTYPE html>"
    echo "<html lang=\"${LANGUAGE}\">"
    echo "<head>"
    echo "<title>${TITLE}</title>"
    echo '<meta charset="utf-8">'
    echo '<meta name="description" content="ŠKODA digital manual">'
    echo '<link href="bootstrap.css" rel="stylesheet" type="text/css"/>'
    echo '<link href="extra.css" rel="stylesheet" type="text/css"/>'
    echo '<style>'
    echo '@media print {'
    echo '  nav#toc { page-break-after: always; }'
    echo '  .section > .section-label { page-break-before: always; }'
    echo '  .section .section > .section-label { page-break-before: auto; }'
    echo '  img { max-width: 100% !important; page-break-inside: avoid; }'
    echo '  table { page-break-inside: avoid; }'
    echo '}'
    echo '</style>'
    echo '</head>'
    echo '<body>'
    handleCover "$MANUAL_LIST_PATH"
    handleToc ".[0]"
    handleSection "./cache" ".[0]"
    echo "</body></html>"
}

# ─── Interactive mode ─────────────────────────────────────────────────────────
function interactiveMode() {
    # Require a real terminal
    if ! [ -t 0 ] || ! [ -t 1 ]; then
        >&2 echo "ERROR: Interactive mode requires a terminal."
        >&2 echo "Run '$(basename "$0") --help' for usage with flags."
        exit 1
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║          ŠKODA Manual Downloader                 ║"
    echo "╚══════════════════════════════════════════════════╝"

    # ── Step 1: Session ────────────────────────────────────────────────────────
    echo ""
    echo "Step 1/4 — Session"

    if [ -n "$COOKIES" ]; then
        echo "  Using existing session cookies."
    else
        if $AUTO_COOKIE; then
            if autoLoadCookies; then
                echo "  Session cookies loaded automatically."
            fi
        fi

        if [ -z "$COOKIES" ]; then
            echo "  Paste browser cookies from digital-manual.skoda-auto.com."
            read -r -p "  Cookies:  " COOKIES
            COOKIES="$(normalizeCookieHeader "$COOKIES")"
        fi

        if [ -n "$COOKIES" ]; then
            echo "  Cookies set."
        else
            >&2 echo "ERROR: No session cookies provided."
            >&2 echo "Open https://www.skoda.dk/apps/manuals/Models and open your manual."
            >&2 echo "Then copy the Cookie header from a request to digital-manual.skoda-auto.com."
            exit 1
        fi
    fi

    # ── Step 2: Language ───────────────────────────────────────────────────────
    echo ""
    echo "Step 2/4 — Language"
    echo ""

    local -a LANG_CODES=("da_DK" "en_GB" "de_DE" "cs_CZ" "sk_SK" "fr_FR" "nl_NL" "pl_PL" "es_ES" "it_IT")
    local -a LANG_NAMES=("Danish" "English (UK)" "German" "Czech" "Slovak" "French" "Dutch" "Polish" "Spanish" "Italian")
    local n_langs=${#LANG_CODES[@]}
    local i
    for ((i=0; i<n_langs; i++)); do
        printf "  %2d)  %-12s  %s\n" "$((i+1))" "${LANG_CODES[$i]}" "${LANG_NAMES[$i]}"
    done
    printf "  %2d)  Other\n" "$((n_langs+1))"
    echo ""

    local lang_choice
    read -r -p "  Choose [1]: " lang_choice
    lang_choice=${lang_choice:-1}

    if [ "$lang_choice" -eq "$((n_langs+1))" ] 2>/dev/null; then
        read -r -p "  Enter language code (e.g. sv_SE): " LANGUAGE
    elif [ "$lang_choice" -ge 1 ] && [ "$lang_choice" -le "$n_langs" ] 2>/dev/null; then
        LANGUAGE="${LANG_CODES[$((lang_choice-1))]}"
    fi
    echo "  → ${LANGUAGE}"

    # Set a working REFERER now that we have LANGUAGE
    REFERER="https://digital-manual.skoda-auto.com/w/${LANGUAGE}/"

    # ── Step 3: Select manual ──────────────────────────────────────────────────
    echo ""
    echo "Step 3/4 — Manual"
    echo ""

    local LIST_FILE="./cache/manual_list_${LANGUAGE}.json"
    echo "  Fetching available manuals..." >&2
    fetchFile "https://digital-manual.skoda-auto.com/api/web/V6/search?query=&facetfilters=topic-type_%7C_welcome&lang=${LANGUAGE}&page=0&pageSize=200" "$LIST_FILE"

    local -a MANUAL_IDS=()
    local -a MANUAL_TITLES=()
    while IFS=$'\t' read -r id title; do
        MANUAL_IDS+=("$id")
        MANUAL_TITLES+=("$title")
    done < <(jq -r '.results[] | [.topicId, (.abstractText // "N/A")] | @tsv' "$LIST_FILE")

    local n_manuals=${#MANUAL_IDS[@]}
    if [ "$n_manuals" -eq 0 ]; then
        >&2 echo "  No manuals found for language ${LANGUAGE}."
        exit 1
    fi

    for ((i=0; i<n_manuals; i++)); do
        printf "  %2d)  %s\n" "$((i+1))" "${MANUAL_TITLES[$i]}"
    done
    echo ""

    local manual_choice
    read -r -p "  Choose [1]: " manual_choice
    manual_choice=${manual_choice:-1}
    if [ "$manual_choice" -lt 1 ] || [ "$manual_choice" -gt "$n_manuals" ] 2>/dev/null; then
        manual_choice=1
    fi
    MANUAL="${MANUAL_IDS[$((manual_choice-1))]}"
    local SELECTED_TITLE="${MANUAL_TITLES[$((manual_choice-1))]}"
    echo "  → ${SELECTED_TITLE}"

    # Update REFERER now that we have MANUAL
    REFERER="https://digital-manual.skoda-auto.com/w/${LANGUAGE}/show/${MANUAL}?ct=${MANUAL}"

    # ── Step 4: Output format ──────────────────────────────────────────────────
    echo ""
    echo "Step 4/4 — Output format"
    echo ""
    echo "  1)  HTML"

    if [ -n "$PDF_RENDERER" ]; then
        echo "  2)  PDF                         (renderer: $PDF_RENDERER)"
        echo "  3)  HTML + PDF"
    else
        echo "  2)  PDF                         (not available — install chromium)"
        echo "  3)  HTML + PDF                  (not available)"
    fi

    echo "  4)  Standalone HTML             (single file, no images/ folder)"

    if [ -n "$PDF_RENDERER" ]; then
        echo "  5)  Standalone HTML + PDF"
    else
        echo "  5)  Standalone HTML + PDF       (not available)"
    fi
    echo ""

    local fmt_choice
    read -r -p "  Choose [1]: " fmt_choice
    fmt_choice=${fmt_choice:-1}

    case $fmt_choice in
        1) DO_HTML=true ;;
        2) if [ -n "$PDF_RENDERER" ]; then DO_PDF=true
           else echo "  No PDF renderer found. Falling back to HTML."; DO_HTML=true; fi ;;
        3) if [ -n "$PDF_RENDERER" ]; then DO_HTML=true; DO_PDF=true
           else echo "  No PDF renderer found. Falling back to HTML only."; DO_HTML=true; fi ;;
        4) DO_HTML=true; STANDALONE=true ;;
        5) if [ -n "$PDF_RENDERER" ]; then DO_HTML=true; STANDALONE=true; DO_PDF=true
           else echo "  No PDF renderer found. Generating standalone HTML only."; DO_HTML=true; STANDALONE=true; fi ;;
        *) DO_HTML=true ;;
    esac

    # ── Confirm ────────────────────────────────────────────────────────────────
    echo ""
    echo "──────────────────────────────────────────────────────"
    echo "  Manual:   ${SELECTED_TITLE}"
    echo "  Language: ${LANGUAGE}"
    echo -n "  Output:   "
    $DO_HTML    && echo -n "HTML "
    $STANDALONE && echo -n "(standalone) "
    $DO_PDF     && echo -n "+ PDF"
    echo ""
    echo "──────────────────────────────────────────────────────"
    echo ""

    local confirm
    read -r -p "  Start download? [Y/n]: " confirm
    confirm=${confirm:-Y}
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo "  Aborted."
        exit 0
    fi
    echo ""
}

# ─── Main flow ────────────────────────────────────────────────────────────────

if $INTERACTIVE; then
    interactiveMode
else
    # Non-interactive: authenticate
    if [ -z "$COOKIES" ] && $AUTO_COOKIE; then
        autoLoadCookies || true
    fi

    if [ -z "$COOKIES" ]; then
        >&2 echo "ERROR: No session cookies found."
        >&2 echo ""
        >&2 echo "Set COOKIES in .env or environment:"
        >&2 echo "  echo \"COOKIES='JSESSIONID=...; BIGip...=...'\" >> .env"
        >&2 echo "Or set COOKIE_FILE in .env:"
        >&2 echo "  echo \"COOKIE_FILE=./skoda_cookies.txt\" >> .env"
        >&2 echo ""
        >&2 echo "Or run without flags for interactive mode: $(basename "$0")"
        exit 1
    fi

    # Set REFERER now that MANUAL and LANGUAGE are known
    REFERER="https://digital-manual.skoda-auto.com/w/${LANGUAGE}/show/${MANUAL}?ct=${MANUAL}"

    # Handle --list
    if $LIST_MANUALS; then
        [ -n "$MANUAL" ] && LANGUAGE="$MANUAL"
        local_list="./cache/manual_list_${LANGUAGE}.json"
        >&2 echo "Fetching available manuals (${LANGUAGE})..."
        fetchFile "https://digital-manual.skoda-auto.com/api/web/V6/search?query=&facetfilters=topic-type_%7C_welcome&lang=${LANGUAGE}&page=0&pageSize=200" "$local_list"
        echo ""
        printf "  %-52s  %s\n" "MANUAL ID" "TITLE"
        printf "  %-52s  %s\n" "---------" "-----"
        jq -r '.results[] | [.topicId, (.abstractText // "N/A")] | @tsv' "$local_list" | \
            while IFS=$'\t' read -r id title; do
                printf "  %-52s  %s\n" "$id" "$title"
            done
        echo ""
        exit 0
    fi

    if [ -z "$MANUAL" ]; then
        >&2 echo "ERROR: No manual ID specified."
        >&2 echo "Use '$(basename "$0") --list ${LANGUAGE}' to see available manuals."
        exit 1
    fi
fi

# ─── Bootstrap CSS ────────────────────────────────────────────────────────────
if [ ! -f "bootstrap.css" ]; then
    >&2 echo "Downloading Bootstrap CSS..."
    curl -s --retry 3 \
        "https://maxcdn.bootstrapcdn.com/bootstrap/3.4.1/css/bootstrap.min.css" \
        -o bootstrap.css
fi

# ─── Download content ─────────────────────────────────────────────────────────
>&2 echo "Fetching table of contents: ${MANUAL} (${LANGUAGE})..."
TOPIC_PATH=./cache/topic.json
fetchFile "https://digital-manual.skoda-auto.com/api/web/V6/topic?key=${MANUAL}&displaytype=topic&language=${LANGUAGE}&query=undefined" "$TOPIC_PATH"

MANUAL_LIST_PATH=./cache/manual_list.json
fetchFile "https://digital-manual.skoda-auto.com/api/web/V6/search?query=&facetfilters=topic-type_%7C_welcome&lang=${LANGUAGE}&page=0&pageSize=200" "$MANUAL_LIST_PATH"

grabImage "$(jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .previewImage" "$MANUAL_LIST_PATH")" "./images"

TOC_PATH=./cache/toc.json
if [ ! -s "$TOC_PATH" ]; then
    jq .trees "$TOPIC_PATH" > "$TOC_PATH"
fi
TOC_CONTENT=$(cat "$TOC_PATH")

TOTAL_SECTIONS=$(echo "${TOC_CONTENT}" | jq '[.. | objects | .linkTarget | select(type == "string" and . != "null")] | length')
TITLE=$(jq -r ".[0].label" "$TOC_PATH")
>&2 echo "Manual: ${TITLE} — ${TOTAL_SECTIONS} sections"

# ─── Output filenames ─────────────────────────────────────────────────────────
MANUAL_NAME_RAW="$(jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .abstractText" "$MANUAL_LIST_PATH" | head -n 1)"
if [ -z "$MANUAL_NAME_RAW" ] || [ "$MANUAL_NAME_RAW" = "null" ]; then
    MANUAL_NAME_RAW="$TITLE"
fi
if [ -z "$MANUAL_NAME_RAW" ] || [ "$MANUAL_NAME_RAW" = "null" ]; then
    MANUAL_NAME_RAW="$MANUAL"
fi
MANUAL_NAME="$(sanitizeFileComponent "$MANUAL_NAME_RAW")"
OUTPUT_TIMESTAMP="$(date '+%d-%m-%Y_%H-%M-%S')"
OUTPUT_BASE="${MANUAL_NAME}_${LANGUAGE}_${OUTPUT_TIMESTAMP}"
OUTPUT_HTML="./${OUTPUT_BASE}.html"
OUTPUT_STANDALONE="./${OUTPUT_BASE}_standalone.html"
OUTPUT_PDF="./${OUTPUT_BASE}.pdf"
>&2 echo "Output base: ${OUTPUT_BASE}"

# ─── Generate HTML ────────────────────────────────────────────────────────────
>&2 echo "Generating HTML..."
generateHtml "$MANUAL_LIST_PATH" > "$OUTPUT_HTML"
>&2 echo "HTML written ($(du -sh "$OUTPUT_HTML" | cut -f1))"

# ─── Standalone ───────────────────────────────────────────────────────────────
if $STANDALONE; then
    makeStandalone "$OUTPUT_HTML" "$OUTPUT_STANDALONE"
fi

# ─── PDF ──────────────────────────────────────────────────────────────────────
if $DO_PDF; then
    PDF_SRC="$OUTPUT_HTML"
    $STANDALONE && [ -f "$OUTPUT_STANDALONE" ] && PDF_SRC="$OUTPUT_STANDALONE"
    makePdf "$PDF_SRC" "$OUTPUT_PDF"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
>&2 echo ""
>&2 echo "Done."
$DO_HTML    && >&2 echo "  HTML:       $(realpath "$OUTPUT_HTML")"
$STANDALONE && >&2 echo "  Standalone: $(realpath "$OUTPUT_STANDALONE")"
$DO_PDF     && >&2 echo "  PDF:        $(realpath "$OUTPUT_PDF")"
