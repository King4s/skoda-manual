# skoda-manual

Download a SKODA digital owner manual to local files (HTML, standalone HTML, and/or PDF).

Based on [jypma/skoda-manual](https://github.com/jypma/skoda-manual), with fixes from [PR #2 (ematt)](https://github.com/jypma/skoda-manual/pull/2) plus:
- Interactive menu mode (`./skoda.sh` with no arguments)
- Cookie-based session with automatic cookie discovery (`COOKIES` optional)
- Resume support with caching in `./cache` and `./images`
- PDF output support via Chromium, wkhtmltopdf, or WeasyPrint

## Requirements

Required:

```bash
sudo apt install curl jq libxml2-utils coreutils python3
```

Optional for PDF output:

```bash
sudo apt install chromium
# or
sudo apt install wkhtmltopdf
# or
pip install weasyprint
```

## Quick Start (Interactive)

Run without arguments:

```bash
cd /opt/skoda-manual
./skoda.sh
```

The interactive menu walks through:
1. Session cookies (auto-detect first, then manual paste fallback)
2. Language selection
3. Manual selection
4. Output format (HTML / PDF / standalone variants)

## Non-interactive Usage

List manuals for a language:

```bash
./skoda.sh --list da_DK
```

Download a manual as HTML:

```bash
./skoda.sh <MANUAL_ID> <LANGUAGE> --html
```

Download HTML + PDF:

```bash
./skoda.sh <MANUAL_ID> <LANGUAGE> --html --pdf
```

Download standalone HTML (single file with embedded assets):

```bash
./skoda.sh <MANUAL_ID> <LANGUAGE> --standalone
```

Clear cache:

```bash
./skoda.sh --clear-cache
```

## Authentication

By default, the script tries to auto-load cookies from:
- `COOKIE_FILE` (Netscape cookie file)
- common local cookie files (for example `/tmp/skoda_cookies.txt`)
- Firefox profile cookies
- Chromium/Chrome profile cookies (when readable)

Manual override is still supported:

```bash
COOKIES='JSESSIONID=abc123; BIGip...=...'
```

You can also pin a cookie file:

```bash
COOKIE_FILE=./skoda_cookies.txt
```

If auto-discovery does not find a valid session, copy cookies manually:
1. Open [www.skoda.dk/apps/manuals/Models](https://www.skoda.dk/apps/manuals/Models)
2. Choose model/manual so it opens `digital-manual.skoda-auto.com`
3. Open DevTools (`F12`) and reload
4. Copy `Cookie:` from a request to `digital-manual.skoda-auto.com`

No dedicated manual account is required for this cookie flow.

## Finding Manual ID

The manual ID is in the manual URL:

```text
https://digital-manual.skoda-auto.com/w/da_DK/show/b6c0b6d20c1b2988ac1445253a0f2c00_3_da_DK
                                                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

## Output Files

The script auto-generates output filenames from the manual title:

`<Manual_Title>_<LANGUAGE>_<DD-MM-YYYY_HH-MM-SS>.ext`

Examples:
- `Superb_Owner's_Manual_da_DK_23-02-2026_15-04-58.html`
- `Superb_Owner's_Manual_da_DK_23-02-2026_15-04-58_standalone.html`
- `Superb_Owner's_Manual_da_DK_23-02-2026_15-04-58.pdf`

For non-standalone HTML, keep these next to the generated `.html` file:
- `extra.css`
- `bootstrap.css`
- `images/`

## Resume Behavior

Downloaded content is cached in:
- `./cache` (JSON/session data)
- `./images` (manual images)

Rerun the same command to resume interrupted downloads.

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `ERROR: No session cookies found` | Auto-discovery found no valid browser/session cookies | Set `COOKIES` manually or set `COOKIE_FILE` |
| `ERROR: Interactive mode requires a terminal` | Interactive mode run in non-TTY environment | Run in a real terminal, or pass flags/manual ID |
| `ERROR: No PDF renderer found` | `--pdf` selected without renderer installed | Install Chromium, wkhtmltopdf, or WeasyPrint |
| Missing sections or images | Session expired or interrupted run | Refresh `COOKIES` and rerun command (resume cache) |
