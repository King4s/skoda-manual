#!/bin/bash
set -e
set +H

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────
IDENTIFIER=""    # VIN (17 chars) or partNumber (e.g. 657012738AR)
MANUAL=""        # topic ID — resolved after session init
LANGUAGE="da_DK"
DO_HTML=false
DO_PDF=false
STANDALONE=false
CLEAR_CACHE=false
INTERACTIVE=false
TOC_CONTENT=""
CURRENT_SECTION=0
TOTAL_SECTIONS=0
MAXSECT=100
ACTIVATE_DELAY=false
PDF_RENDERER=""
REFERER="https://digital-manual.skoda-auto.com/"
SESSION_JAR="./cache/session.jar"

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
        --clear-cache) CLEAR_CACHE=true;   shift ;;
        --help|-h)
            cat <<EOF
Usage: $(basename "$0") [OPTIONS] [VIN_OR_PARTNUMBER] [LANGUAGE]

  Run without arguments for interactive mode.

  VIN_OR_PARTNUMBER:
    VIN (17 chars)             e.g. TMBZZZ3FZN1234567
    Part number (VW/Škoda)     e.g. 657012738AR

Options:
  --html          Generate HTML output (default)
  --pdf           Generate PDF (requires chromium, wkhtmltopdf, or weasyprint)
  --standalone    Embed all assets into a single HTML file
  --clear-cache   Delete ./cache/ and ./images/
  --help          Show this help

Examples:
  $(basename "$0")
  $(basename "$0") 657012738AR da_DK --html
  $(basename "$0") TMBZZZ3FZN1234567 da_DK --html
  $(basename "$0") 657012738AR da_DK --standalone
  $(basename "$0") --clear-cache
EOF
            exit 0 ;;
        --*)
            >&2 echo "ERROR: Unknown option: $1"
            >&2 echo "Run '$(basename "$0") --help' for usage."
            exit 1 ;;
        *)
            [ -z "$IDENTIFIER" ] && IDENTIFIER="$1" || LANGUAGE="$1"
            shift ;;
    esac
done

# Determine mode
if [ -z "$IDENTIFIER" ] && ! $CLEAR_CACHE; then
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

# ─── Session ──────────────────────────────────────────────────────────────────
function initSession() {
    local POSTDATA
    local ID="${1:-$IDENTIFIER}"

    # Detect VIN (17 alphanumeric chars) vs partNumber
    if [[ "$ID" =~ ^[A-HJ-NPR-Z0-9]{17}$ ]]; then
        POSTDATA="vin=${ID}&uiLanguage=${LANGUAGE}&importerId=004"
        >&2 echo "Initialising session with VIN..."
    else
        POSTDATA="partNumber=${ID}&uiLanguage=${LANGUAGE}&importerId=004"
        >&2 echo "Initialising session with part number..."
    fi

    curl -s -c "${SESSION_JAR}" -o /dev/null \
        -X POST "https://digital-manual.skoda-auto.com/api/entrypoint/V1/direct/" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H 'Origin: https://www.skoda.dk' \
        -H 'Referer: https://www.skoda.dk/apps/manuals/Models' \
        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36' \
        -H 'Sec-Fetch-Site: cross-site' \
        -H 'Sec-Fetch-Mode: navigate' \
        -H 'Sec-Fetch-Dest: document' \
        --data "${POSTDATA}"

    # Verify session
    local CHECK
    CHECK=$(curl -s -b "${SESSION_JAR}" \
        -H 'Accept: application/json' \
        "https://digital-manual.skoda-auto.com/api/users/V1/getuser")
    if ! echo "${CHECK}" | grep -q '"username":"Direct_PN"'; then
        >&2 echo "ERROR: Session invalid. Check that the VIN or part number is correct and belongs to a Škoda."
        exit 1
    fi
    >&2 echo "Session ready."
}

function resolveManualId() {
    # After auth, find the topic ID accessible via this session
    local SEARCH_FILE="./cache/manual_list_${LANGUAGE}.json"
    rm -f "${SEARCH_FILE}"
    fetchFile "https://digital-manual.skoda-auto.com/api/web/V6/search?query=&facetfilters=topic-type_%7C_welcome&lang=${LANGUAGE}&page=0&pageSize=200" "${SEARCH_FILE}"
    MANUAL=$(jq -r '.results[0].topicId // empty' "${SEARCH_FILE}")
    if [ -z "${MANUAL}" ]; then
        >&2 echo "ERROR: No manual found for this VIN/part number in language ${LANGUAGE}."
        >&2 echo "Try a different language (e.g. en_GB)."
        exit 1
    fi
    >&2 echo "Manual resolved: ${MANUAL}"
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
            -b "${SESSION_JAR}" -c "${SESSION_JAR}" \
            -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36' \
            -H 'Accept: application/json, text/plain, */*' \
            -H 'Accept-Language: da-DK,da;q=0.9,en;q=0.5' \
            -H "Referer: $REFERER" \
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
        >&2 echo "Session expired — reinitialising..."
        initSession
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
        -b "${SESSION_JAR}" -c "${SESSION_JAR}" \
        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36' \
        -H 'Accept: image/avif,image/webp,*/*' \
        -H 'Accept-Language: da-DK,da;q=0.9,en;q=0.5' \
        -H "Referer: $REFERER" \
        -H 'Sec-Fetch-Dest: image' \
        -H 'Sec-Fetch-Mode: no-cors' \
        -H 'Sec-Fetch-Site: same-origin' \
        > "${DESTINATION}"
    ACTIVATE_DELAY=true

    if grep -q "An Authentication object was not found in the SecurityContext" "${DESTINATION}" 2>/dev/null; then
        rm -f "${DESTINATION}"
        >&2 echo "Session expired (image) — reinitialising..."
        initSession
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

    # ── Step 1: Language ───────────────────────────────────────────────────────
    echo ""
    echo "Step 1/3 — Language"
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

    # ── Step 2: VIN or partNumber ──────────────────────────────────────────────
    echo ""
    echo "Step 2/3 — VIN or part number"
    echo ""
    echo "  Enter the car's VIN (17 chars, e.g. TMBZZZ3FZN1234567)"
    echo "  or part number (e.g. 657012738AR)."
    echo "  The VIN is found in your car documents or on the dashboard."
    echo ""

    local id_input
    read -r -p "  VIN or part number: " id_input
    if [ -z "$id_input" ]; then
        >&2 echo "ERROR: No VIN or part number provided."
        exit 1
    fi
    IDENTIFIER="$id_input"
    echo "  → ${IDENTIFIER}"

    # Initialise session now that we have IDENTIFIER and LANGUAGE
    REFERER="https://digital-manual.skoda-auto.com/w/${LANGUAGE}/"
    initSession
    resolveManualId

    local SELECTED_TITLE
    SELECTED_TITLE=$(jq -r '.results[0].abstractText // .results[0].title // "Unknown"' \
        "./cache/manual_list_${LANGUAGE}.json" 2>/dev/null)
    echo "  → Found: ${SELECTED_TITLE}"

    # Update REFERER now that we have MANUAL
    REFERER="https://digital-manual.skoda-auto.com/w/${LANGUAGE}/show/${MANUAL}?ct=${MANUAL}"

    # ── Step 3: Output format ──────────────────────────────────────────────────
    echo ""
    echo "Step 3/3 — Output format"
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
    if [ -z "$IDENTIFIER" ]; then
        >&2 echo "ERROR: No VIN or part number specified."
        >&2 echo "Run '$(basename "$0") --help' for usage."
        exit 1
    fi

    REFERER="https://digital-manual.skoda-auto.com/w/${LANGUAGE}/"
    initSession
    resolveManualId
    REFERER="https://digital-manual.skoda-auto.com/w/${LANGUAGE}/show/${MANUAL}?ct=${MANUAL}"
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

MANUAL_LIST_PATH="./cache/manual_list_${LANGUAGE}.json"
# Already fetched by resolveManualId — only refetch if missing
if [ ! -s "${MANUAL_LIST_PATH}" ]; then
    fetchFile "https://digital-manual.skoda-auto.com/api/web/V6/search?query=&facetfilters=topic-type_%7C_welcome&lang=${LANGUAGE}&page=0&pageSize=200" "$MANUAL_LIST_PATH"
fi

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
