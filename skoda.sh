#!/bin/bash
set -e
set +H

MANUAL=${1:-a2f0321d91cc34bfac1445252fd5b3f4_3_en_GB}
LANGUAGE=${2:-en_GB}
REFERER="https://digital-manual.skoda-auto.com/w/${LANGUAGE}/show/${MANUAL}?ct=${MANUAL}"
TOC_CONTENT=""
TOC=true
CURRENT_SECTION=0
TOTAL_SECTIONS=0

mkdir -p ./images
mkdir -p ./cache

# Check required dependencies
for cmd in curl jq xmllint shuf base64; do
    if ! command -v "$cmd" &>/dev/null; then
        >&2 echo "ERROR: Required command not found: $cmd"
        >&2 echo "Install with: sudo apt install curl jq libxml2-utils coreutils"
        exit 1
    fi
done

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
        >&2 echo "Option 1 — automatic login with username and password:"
        >&2 echo "  export USERNAME='your@email.com'"
        >&2 echo "  export PASSWORD='your-password'"
        >&2 echo "  ./skoda.sh ${MANUAL} ${LANGUAGE} > manual.html"
        >&2 echo ""
        >&2 echo "Option 2 — manual cookie (see README.md):"
        >&2 echo "  export COOKIES='your-cookie-string-from-browser'"
        >&2 echo "  ./skoda.sh ${MANUAL} ${LANGUAGE} > manual.html"
        exit 1
    fi
fi

MAXSECT=100
ACTIVATE_DELAY=false

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
        >&2 echo "Session expired while fetching image."
        if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
            doLogin
        else
            sleep $(shuf -i 1-5 -n 1)
        fi
        grabImage "$IMG" "$DEST_PATH" $(( RETRY + 1 ))
    fi
}

# Returns a safe HTML id for a section: prefer the linkTarget, fall back to
# a URL-safe base64 encoding of the label (no line wraps, no +/= chars).
function sectionId() {
    local LINK=$1
    local LABEL=$2
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

>&2 echo "Fetching table of contents for manual: ${MANUAL} (${LANGUAGE})..."

TOPIC_PATH=./cache/topic.json
fetchFile "https://digital-manual.skoda-auto.com/api/web/V6/topic?key=${MANUAL}&displaytype=topic&language=${LANGUAGE}&query=undefined" "$TOPIC_PATH"

>&2 echo "Fetching manual list..."
MANUAL_LIST_PATH=./cache/manual_list.json
fetchFile "https://digital-manual.skoda-auto.com/api/web/V6/search?query=&facetfilters=topic-type_%7C_welcome&lang=${LANGUAGE}&page=0&pageSize=200" "$MANUAL_LIST_PATH"

>&2 echo "Fetching cover image..."
grabImage "$(cat "$MANUAL_LIST_PATH" | jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .previewImage")" "./images"

TOC_PATH=./cache/toc.json
if [ ! -s "$TOC_PATH" ]; then
    cat "$TOPIC_PATH" | jq .trees > "$TOC_PATH"
fi
TOC_CONTENT=$(cat "$TOC_PATH")

TOTAL_SECTIONS=$(echo "${TOC_CONTENT}" | jq '[.. | objects | .linkTarget | select(type == "string" and . != "null")] | length')
>&2 echo "Manual contains ${TOTAL_SECTIONS} sections."

TITLE=$(cat "$TOC_PATH" | jq -r ".[0].label")

echo "<!DOCTYPE html>"
echo "<html lang=\"${LANGUAGE}\">"
echo "<head>"
echo "<title>${TITLE}</title>"
echo '<meta name="description" content="ŠKODA digital manual">'
echo '<meta name="keywords" content="ŠKODA, manual">'
echo '<meta name="author" content="ŠKODA">'
echo '<link href="extra.css" rel="stylesheet" type="text/css"/>'
echo '<link href="bootstrap.css" rel="stylesheet" type="text/css"/>'
echo '</head>'
echo '<body>'
handleCover "$MANUAL_LIST_PATH"
handleToc ".[0]"
handleSection "./cache" ".[0]"
echo "</body>"
echo "</html>"
