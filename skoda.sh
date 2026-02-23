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
TOC_CONTENT=""
TOC=true
CURRENT_SECTION=0
TOTAL_SECTIONS=0
MAXSECT=100
ACTIVATE_DELAY=false

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
        --help|-h)
            cat <<EOF
Usage: $(basename "$0") [OPTIONS] [MANUAL_ID] [LANGUAGE]

Options:
  --html          Generate HTML output (default if no format specified)
  --pdf           Generate PDF output (requires chromium, wkhtmltopdf, or weasyprint)
  --standalone    Embed all assets in HTML (single self-contained file, no images/ needed)
  --list          List available manuals for LANGUAGE (default: en_GB)
  --clear-cache   Delete ./cache/ and ./images/
  --help          Show this help

Authentication — set in .env file or environment:
  USERNAME        ŠKODA account email
  PASSWORD        ŠKODA account password
  COOKIES         Browser session cookies (alternative to username/password)

Examples:
  $(basename "$0") --list da_DK
  $(basename "$0") b6c0b6d20c1b2988ac1445253a0f2c00_3_da_DK da_DK --html
  $(basename "$0") b6c0b6d20c1b2988ac1445253a0f2c00_3_da_DK da_DK --html --pdf
  $(basename "$0") b6c0b6d20c1b2988ac1445253a0f2c00_3_da_DK da_DK --standalone
  $(basename "$0") --clear-cache

.env file example:
  USERNAME=your@email.com
  PASSWORD=your-password
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

# Default to HTML if no format specified
$DO_HTML || $DO_PDF || DO_HTML=true

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

PDF_RENDERER=""
if $DO_PDF; then
    for cmd in chromium chromium-browser google-chrome google-chrome-stable wkhtmltopdf weasyprint; do
        if command -v "$cmd" &>/dev/null; then
            PDF_RENDERER="$cmd"
            break
        fi
    done
    if [ -z "$PDF_RENDERER" ]; then
        >&2 echo "ERROR: No PDF renderer found. Install one of:"
        >&2 echo "  sudo apt install chromium      (best quality)"
        >&2 echo "  sudo apt install wkhtmltopdf   (alternative)"
        >&2 echo "  pip install weasyprint         (alternative)"
        exit 1
    fi
    >&2 echo "PDF renderer: $PDF_RENDERER"
fi

# ─── Setup ────────────────────────────────────────────────────────────────────
mkdir -p ./images ./cache
REFERER="https://digital-manual.skoda-auto.com/w/${LANGUAGE}/show/${MANUAL}?ct=${MANUAL}"

# ─── Authentication ───────────────────────────────────────────────────────────
function doLogin() {
    local JAR="./cache/session.jar"
    >&2 echo "Logging in as ${USERNAME}..."
    local LOCATION
    LOCATION=$(curl -s -c "${JAR}" -D - \
        -X POST "https://digital-manual.skoda-auto.com/public/login" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H "Referer: https://digital-manual.skoda-auto.com/public/login/${LANGUAGE}/" \
        --data-urlencode "username=${USERNAME}" \
        --data-urlencode "password=${PASSWORD}" \
        -o /dev/null | grep "^Location:" | tr -d '\r')
    if echo "${LOCATION}" | grep -q "error"; then
        >&2 echo "ERROR: Incorrect username or password."
        exit 1
    fi
    COOKIES=$(awk '!/^#/ && NF==7 {printf "%s=%s; ", $6, $7}' "${JAR}" | sed 's/; $//')
    >&2 echo "Login successful."
}

if [ -z "$COOKIES" ]; then
    if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
        doLogin
    else
        >&2 echo "ERROR: No login credentials found."
        >&2 echo ""
        >&2 echo "Tip — create a .env file in this directory:"
        >&2 echo "  echo 'USERNAME=your@email.com' >> .env"
        >&2 echo "  echo 'PASSWORD=your-password'  >> .env"
        >&2 echo ""
        >&2 echo "Or export environment variables:"
        >&2 echo "  export USERNAME='your@email.com' PASSWORD='your-password'"
        exit 1
    fi
fi

# ─── HTTP helpers ─────────────────────────────────────────────────────────────
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
        if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
            doLogin
        else
            >&2 echo "WARNING: Cannot re-login automatically. Set USERNAME+PASSWORD for auto re-login."
            sleep $(shuf -i 1-5 -n 1)
        fi
        fetchFile "$URL" "${DESTINATION}" $(( RETRY + 1 ))
    fi
}

function grabImage() {
    local IMG=$1
    local DEST_PATH=$2
    local RETRY=${3:-0}

    if [ -z "${IMG}" ] || [ "${IMG}" = "null" ]; then
        return 0
    fi
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
        if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
            doLogin
        else
            sleep $(shuf -i 1-5 -n 1)
        fi
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
    local JSONPATH=$1
    local HTMLPATH=$2

    local HTMLBODY
    HTMLBODY="$(cat "${JSONPATH}" | jq -r ".bodyHtml")"
    local LINK_STATE_KEYS
    LINK_STATE_KEYS="$(cat "${JSONPATH}" | jq -r ".linkState | keys[]")"

    for KEY in ${LINK_STATE_KEYS[@]}; do
        >&2 echo "  Replacing link: ${KEY}"
        local ANCHOR_TO_REPLACE
        ANCHOR_TO_REPLACE="$(echo "$HTMLBODY" | xmllint --xpath "//html//a[@id='"${KEY}"']" -)"
        local LINK_TYPE
        LINK_TYPE="$(cat "${JSONPATH}" | jq -r ".linkState[] | select(.id==\"${KEY}\") | .linkType")"
        local ANCHOR_MODIFIED
        if [ "$LINK_TYPE" == "dynamic" ]; then
            local TARGET
            TARGET="$(cat "${JSONPATH}" | jq -r ".linkState[] | select(.id==\"${KEY}\") | .target")"
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
    local CURRENTPATH=$1
    local EXPR=$2
    local LABEL
    LABEL="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.label" | sed 's|<[^>]*>||g' | sed 's|\/|, |g')"
    local CHILDREN
    CHILDREN="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.children | length")"
    local LINK
    LINK=$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.linkTarget")

    local ID
    ID=$(sectionId "$LINK" "$LABEL")

    if [ -n "$ID" ] && [ "$ID" != "null" ]; then
        echo "<div class='section' id='${ID}'>"
    else
        echo "<div class='section'>"
    fi
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

    local i
    local TOP
    TOP=$(( CHILDREN > MAXSECT ? MAXSECT : CHILDREN ))
    for ((i=0;i<TOP;i++)); do
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
    local i
    local TOP
    TOP=$(( CHILDREN > MAXSECT ? MAXSECT : CHILDREN ))
    echo '<ol>'
    for ((i=0;i<TOP;i++)); do
        handleTocItem "$EXPR.children[${i}]"
    done
    echo '</ol>'
    echo '</li>'
}

function handleToc() {
    local EXPR=$1
    local LABEL
    LABEL="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.label" | sed 's|<[^>]*>||g' | sed 's|\/|, |g')"
    local CHILDREN
    CHILDREN="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.children | length")"
    local i
    local TOP
    TOP=$(( CHILDREN > MAXSECT ? MAXSECT : CHILDREN ))

    >&2 echo "Generating table of contents..."

    echo '<nav id="toc" aria-labelledby="toc-label">'
    echo "<h2 id=\"toc-label\">${LABEL}</h2>"
    echo '<ol>'
    for ((i=0;i<TOP;i++)); do
        handleTocItem "$EXPR.children[${i}]"
    done
    echo '</ol>'
    echo '</nav>'
}

function handleCover() {
    local MANUAL_LIST_PATH=$1
    local COVER_IMAGE
    COVER_IMAGE="$(cat "${MANUAL_LIST_PATH}" | jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .previewImage")"
    local COVER_ABSTRACT
    COVER_ABSTRACT="$(cat "${MANUAL_LIST_PATH}" | jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .abstractText")"
    local COVER_PART
    COVER_PART="$(cat "${MANUAL_LIST_PATH}" | jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .facets[0].\"1\"[0]")"

    echo '<div class="panel panel-default">'
    echo '<div class="panel-heading">'
    echo '<img class="content blockimage" src="./images/'"${COVER_IMAGE}"'" alt="Card image">'
    echo '</div>'
    echo '<div class="panel-body">'
    echo '<h1 class="card-title">'"${COVER_ABSTRACT}"'</h1>'
    echo "${COVER_PART}"
    echo '</div>'
    echo '</div>'
}

# ─── Output helpers ───────────────────────────────────────────────────────────
function makeStandalone() {
    local HTML_IN=$1
    local HTML_OUT=$2
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
    local HTML_FILE=$1
    local PDF_FILE=$2
    local ABS_HTML
    ABS_HTML="$(realpath "$HTML_FILE")"
    local ABS_PDF
    ABS_PDF="$(realpath "$PDF_FILE")"

    >&2 echo "Generating PDF with ${PDF_RENDERER}..."
    case "$PDF_RENDERER" in
        chromium*|google-chrome*)
            "$PDF_RENDERER" \
                --headless \
                --disable-gpu \
                --no-sandbox \
                --disable-dev-shm-usage \
                --print-to-pdf="${ABS_PDF}" \
                --no-pdf-header-footer \
                "file://${ABS_HTML}" 2>/dev/null
            ;;
        wkhtmltopdf)
            wkhtmltopdf \
                --enable-local-file-access \
                --no-stop-slow-scripts \
                --quiet \
                "${ABS_HTML}" "${ABS_PDF}" 2>/dev/null
            ;;
        weasyprint)
            weasyprint "${ABS_HTML}" "${ABS_PDF}" 2>/dev/null
            ;;
    esac
    >&2 echo "PDF written ($(du -sh "$ABS_PDF" | cut -f1))"
}

function generateHtml() {
    local MANUAL_LIST_PATH=$1
    echo "<!DOCTYPE html>"
    echo "<html lang=\"${LANGUAGE}\">"
    echo "<head>"
    echo "<title>${TITLE}</title>"
    echo '<meta charset="utf-8">'
    echo '<meta name="description" content="ŠKODA digital manual">'
    echo '<meta name="keywords" content="ŠKODA, manual">'
    echo '<meta name="author" content="ŠKODA">'
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
    echo "</body>"
    echo "</html>"
}

# ─── List manuals ─────────────────────────────────────────────────────────────
if $LIST_MANUALS; then
    # First positional arg is treated as language when using --list
    [ -n "$MANUAL" ] && LANGUAGE="$MANUAL"
    LIST_FILE="./cache/manual_list_${LANGUAGE}.json"
    >&2 echo "Fetching available manuals (${LANGUAGE})..."
    fetchFile "https://digital-manual.skoda-auto.com/api/web/V6/search?query=&facetfilters=topic-type_%7C_welcome&lang=${LANGUAGE}&page=0&pageSize=200" "$LIST_FILE"
    echo ""
    printf "  %-52s  %s\n" "MANUAL ID" "TITLE"
    printf "  %-52s  %s\n" "---------" "-----"
    jq -r '.results[] | [.topicId, (.abstractText // "N/A")] | @tsv' "$LIST_FILE" | \
        while IFS=$'\t' read -r id title; do
            printf "  %-52s  %s\n" "$id" "$title"
        done
    echo ""
    exit 0
fi

# ─── Require MANUAL_ID ────────────────────────────────────────────────────────
if [ -z "$MANUAL" ]; then
    >&2 echo "ERROR: No manual ID specified."
    >&2 echo "Use '$(basename "$0") --list ${LANGUAGE}' to see available manuals."
    >&2 echo "Use '$(basename "$0") --help' for usage."
    exit 1
fi

# ─── Bootstrap CSS ────────────────────────────────────────────────────────────
if [ ! -f "bootstrap.css" ]; then
    >&2 echo "Downloading Bootstrap CSS..."
    curl -s --retry 3 \
        "https://maxcdn.bootstrapcdn.com/bootstrap/3.4.1/css/bootstrap.min.css" \
        -o bootstrap.css
    >&2 echo "Bootstrap CSS downloaded."
fi

# ─── Download content ─────────────────────────────────────────────────────────
>&2 echo "Fetching table of contents for manual: ${MANUAL} (${LANGUAGE})..."
TOPIC_PATH=./cache/topic.json
fetchFile "https://digital-manual.skoda-auto.com/api/web/V6/topic?key=${MANUAL}&displaytype=topic&language=${LANGUAGE}&query=undefined" "$TOPIC_PATH"

>&2 echo "Fetching manual list..."
MANUAL_LIST_PATH=./cache/manual_list.json
fetchFile "https://digital-manual.skoda-auto.com/api/web/V6/search?query=&facetfilters=topic-type_%7C_welcome&lang=${LANGUAGE}&page=0&pageSize=200" "$MANUAL_LIST_PATH"

>&2 echo "Fetching cover image..."
grabImage "$(jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .previewImage" "$MANUAL_LIST_PATH")" "./images"

TOC_PATH=./cache/toc.json
if [ ! -s "$TOC_PATH" ]; then
    jq .trees "$TOPIC_PATH" > "$TOC_PATH"
fi
TOC_CONTENT=$(cat "$TOC_PATH")

TOTAL_SECTIONS=$(echo "${TOC_CONTENT}" | jq '[.. | objects | .linkTarget | select(type == "string" and . != "null")] | length')
TITLE=$(jq -r ".[0].label" "$TOC_PATH")

>&2 echo "Manual: ${TITLE} — ${TOTAL_SECTIONS} sections"

# ─── Generate HTML ────────────────────────────────────────────────────────────
HTML_FILE="./manual.html"
>&2 echo "Generating HTML..."
generateHtml "$MANUAL_LIST_PATH" > "$HTML_FILE"
>&2 echo "HTML written: $(realpath "$HTML_FILE") ($(du -sh "$HTML_FILE" | cut -f1))"

# ─── Standalone HTML ──────────────────────────────────────────────────────────
if $STANDALONE; then
    makeStandalone "$HTML_FILE" "./manual-standalone.html"
fi

# ─── PDF ──────────────────────────────────────────────────────────────────────
if $DO_PDF; then
    # Use standalone HTML for PDF if available (avoids file:// path issues)
    if $STANDALONE && [ -f "./manual-standalone.html" ]; then
        makePdf "./manual-standalone.html" "./manual.pdf"
    else
        makePdf "$HTML_FILE" "./manual.pdf"
    fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
>&2 echo ""
>&2 echo "Done."
$DO_HTML    && >&2 echo "  HTML:       $(realpath "$HTML_FILE")"
$STANDALONE && >&2 echo "  Standalone: $(realpath ./manual-standalone.html)"
$DO_PDF     && >&2 echo "  PDF:        $(realpath ./manual.pdf)"
