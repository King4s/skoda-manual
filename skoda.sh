#!/bin/bash
set -e
set +H

MANUAL=${1:-a2f0321d91cc34bfac1445252fd5b3f4_3_en_GB}
LANGUAGE=${2:-en_GB}
REFERER="https://digital-manual.skoda-auto.com/w/${LANGUAGE}/show/${MANUAL}?ct=${MANUAL}"
TOC_CONTENT=""
TOC=true

mkdir -p ./images
mkdir -p ./cache

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

function fecthFile() {
    local URL=$1
    local DESTINATION=$2
    if [ ! -s "${DESTINATION}" ]; then
        >&2 echo "Fetching ${DESTINATION} from ${URL}"
        rm "${DESTINATION}" 2> /dev/null
        curl "${URL}" --retry 100 --retry-all-errors --compressed \
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
        if grep -q "An Authentication object was not found in the SecurityContext" "${DESTINATION}"; then
            rm "${DESTINATION}" 2> /dev/null
            sleep $(shuf -i 1-5 -n 1)
            fecthFile $URL "${DESTINATION}"
        fi
    else
        if grep -q "An Authentication object was not found in the SecurityContext" "${DESTINATION}"; then
            rm "${DESTINATION}" 2> /dev/null
            sleep $(shuf -i 1-5 -n 1)
            fecthFile $URL "${DESTINATION}"
        else
            >&2 echo "Fetching ${DESTINATION} from cache"
        fi
    fi
}

function grabImage() {
    local IMG=$1
    local DEST_PATH=$2
    local DESTINATION=$DEST_PATH/$IMG

    if [ ! -s "${DESTINATION}" ]; then
        local URL="https://digital-manual.skoda-auto.com/public/media?lang=${LANGUAGE}&key=${IMG}"
        >&2 echo "Fetching image ${DESTINATION}"
        rm "${DESTINATION}" 2> /dev/null
        curl "${URL}" --retry 100 --retry-all-errors \
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
        if grep -q "An Authentication object was not found in the SecurityContext" "${DESTINATION}"; then
            rm "${DESTINATION}" 2> /dev/null
            sleep $(shuf -i 1-5 -n 1)
            grabImage $IMG $DEST_PATH
        fi
    else
        if grep -q "An Authentication object was not found in the SecurityContext" "${DESTINATION}"; then
            rm "${DESTINATION}" 2> /dev/null
            sleep $(shuf -i 1-5 -n 1)
            grabImage $IMG $DEST_PATH
        else
            >&2 echo "Fetching image ${DESTINATION} from cache"
        fi
    fi
}

function handleSectionContent2Html() {
    local JSONPATH=$1
    local HTMLPATH=$2

    local HTMLBODY="$(cat "${JSONPATH}" | jq -r ".bodyHtml")"
    local LINK_STATE_KEYS="$(cat "${JSONPATH}" | jq -r ".linkState | keys[]")"

    for KEY in ${LINK_STATE_KEYS[@]}; do
        >&2 echo "Replacing link for ${KEY}"

        local ANCHOR_TO_REPLACE="$(echo $HTMLBODY | xmllint --xpath "//html//a[@id='"${KEY}"']" -)"

        local LINK_TYPE="$(cat "${JSONPATH}" | jq -r ".linkState[] | select(.id==\"${KEY}\") | .linkType")"
        if [ $LINK_TYPE == "dynamic" ]; then
            local TARGET="$(cat "${JSONPATH}" | jq -r ".linkState[] | select(.id==\"${KEY}\") | .target")"
            local ANCHOR_MODIFIED="$(echo $ANCHOR_TO_REPLACE | sed 's|href="#"|href="#'"${TARGET}"'"|g')"
        else
            local ANCHOR_MODIFIED="$(echo $ANCHOR_TO_REPLACE | sed -E 's|href=\"([^.]*)\.html#([^\"]*)\"|href=\"#\1\"|')"
        fi
        HTMLBODY="$(echo "${HTMLBODY/"$ANCHOR_TO_REPLACE"/"$ANCHOR_MODIFIED"}")"
    done

    echo $HTMLBODY > "${HTMLPATH}"
    echo $HTMLBODY \
        | sed 's|<?[-A-Za-z0-9 "=\.]*?>||g' \
        | sed 's|<!DOCTYPE.*||g' \
        | sed 's|^  PUBLIC ".*||g' \
        | sed 's|<html[0-9"= a-z\-]*>||g' \
        | sed 's|</html>||g' \
        | sed 's/data-src="https:\/\/digital-manual.skoda-auto.com\/default\/public\/media?lang='"${LANGUAGE}"'&amp;key=/src="images\//g'
}

function handleSection() {
    local TOCPATH=$1
    local CURRENTPATH=$2
    local EXPR=$3
    local LABEL="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.label" | sed 's|<[^>]*>||g' | sed 's|\/|, |g')"
    local CHILDREN="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.children | length")"
    local LINK=$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.linkTarget")
    >&2 echo "$EXPR : $LABEL (${CHILDREN} children)"
    local ID
    if [ -n "$LINK" ] && [ "$LINK" != "null" ]; then
        ID="$LINK"
    else
        ID=$(echo "$LABEL" | base64)
    fi

    if [ -n "$ID" ] && [ "$ID" != "null" ]; then
        echo "<div class='section' id='${ID}'>"
    else
        echo "<div class='section'>"
    fi
    echo "<div class='section-label'>${LABEL^}</div>"

    local WORKINGPATH="${CURRENTPATH}/${LABEL}"
    mkdir -p "${WORKINGPATH}"

    if [ -n "$LINK" ] && [ "$LINK" != "null" ]; then
        local CURRENT_PAGE_JSON="${WORKINGPATH}/${LABEL}.json"
        local CURRENT_PAGE_HTML="${CURRENT_PAGE_JSON}.html"

        fecthFile "https://digital-manual.skoda-auto.com/api/vw-topic/V1/topic?key=${LINK}&displaytype=desktop&language=${LANGUAGE}" "${CURRENT_PAGE_JSON}"
        handleSectionContent2Html "${CURRENT_PAGE_JSON}" "${CURRENT_PAGE_HTML}"

        while read IMG; do
            grabImage $IMG "./images"
        done < <(xmllint --xpath "//html//img/@data-src" "${CURRENT_PAGE_HTML}" 2>/dev/null \
            | sed 's/ data-src="https:\/\/digital-manual.skoda-auto.com\/default\/public\/media?lang='"${LANGUAGE}"'&amp;key=\(.*\)"/\1/g' \
            | sed 's/&amp;/\&/g')
    fi

    local i
    local TOP
    TOP=$(( CHILDREN > MAXSECT ? MAXSECT : CHILDREN ))
    for ((i=0;i<TOP;i++)); do
        if [ "$ACTIVATE_DELAY" = true ]; then
            >&2 echo "Waiting before next section: $EXPR : $LABEL"
            sleep $(shuf -i 5-15 -n 1)
            ACTIVATE_DELAY=false
        fi

        handleSection $TOCPATH "${WORKINGPATH}" "$EXPR.children[${i}]"
    done

    echo "</div>"
}

function handleTocItem() {
    local TOCPATH=$1
    local EXPR=$2
    local PREFIX=$3
    local LABEL="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.label" | sed 's|<[^>]*>||g' | sed 's|\/|, |g')"
    local CHILDREN="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.children | length")"
    local LINK=$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.linkTarget")
    local ID
    if [ -n "$LINK" ] && [ "$LINK" != "null" ]; then
        ID="$LINK"
    else
        ID=$(echo "$LABEL" | base64)
    fi

    echo "<li><a href='#${ID}'>${LABEL^}</a>"

    local i
    local TOP
    TOP=$(( CHILDREN > MAXSECT ? MAXSECT : CHILDREN ))
    if $TOC; then
        echo '<ol>'
    fi
    for ((i=0;i<TOP;i++)); do
        handleTocItem $TOCPATH "$EXPR.children[${i}]" "${PREFIX}.$((i+1))"
    done
    if $TOC; then
        echo '</ol>'
    fi
}

function handleToc() {
    local TOCPATH=$1
    local EXPR=$2
    local PREFIX=$3
    local LABEL="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.label" | sed 's|<[^>]*>||g' | sed 's|\/|, |g')"
    local CHILDREN="$(echo "${TOC_CONTENT}" | jq -r "${EXPR}.children | length")"

    local i
    local TOP
    TOP=$(( CHILDREN > MAXSECT ? MAXSECT : CHILDREN ))

    >&2 echo "Generating table of contents..."

    echo '<nav id="toc" aria-labelledby="toc-label">'
    echo "<h2 id=\"toc-label\">${LABEL}</h2>"

    echo '<ol>'
    for ((i=0;i<TOP;i++)); do
        handleTocItem $TOCPATH "$EXPR.children[${i}]" "${PREFIX}.$((i+1))"
    done
    echo '</ol>'
    echo '</nav>'
}

function handleCover() {
    local MANUAL_LIST_PATH=$1

    local COVER_IMAGE="$(cat "${MANUAL_LIST_PATH}" | jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .previewImage")"
    local COVER_ABSTRACT="$(cat "${MANUAL_LIST_PATH}" | jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .abstractText")"
    local COVER_PART="$(cat "${MANUAL_LIST_PATH}" | jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .facets[0].\"1\"[0]")"

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
fecthFile "https://digital-manual.skoda-auto.com/api/web/V6/topic?key=${MANUAL}&displaytype=topic&language=${LANGUAGE}&query=undefined" $TOPIC_PATH

>&2 echo "Fetching manual list..."
MANUAL_LIST_PATH=./cache/manual_list.json
fecthFile "https://digital-manual.skoda-auto.com/api/web/V6/search?query=&facetfilters=topic-type_%7C_welcome&lang=${LANGUAGE}&page=0&pageSize=20" $MANUAL_LIST_PATH

>&2 echo "Fetching cover image..."
grabImage "$(cat ./cache/manual_list.json | jq -r ".results[] | select(.topicId==\"${MANUAL}\") | .previewImage")" "./images"

TOC_PATH=./cache/toc.json
if [ ! -s $TOC_PATH ]; then
    cat $TOPIC_PATH | jq .trees > ${TOC_PATH}
fi
TOC_CONTENT=$(cat $TOC_PATH)

TITLE=$(cat "${TOC_PATH}" | jq -r ".[0].label")

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
handleCover $MANUAL_LIST_PATH
handleToc $TOC_PATH ".[0]" ""
handleSection $TOC_PATH "./cache" ".[0]"
echo '</div>'
echo "</body>"
echo "</html>"
