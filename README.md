# skoda-manual

Download a SKODA digital owner manual to local files (HTML, standalone HTML, and/or PDF).

Based on [jypma/skoda-manual](https://github.com/jypma/skoda-manual), with fixes from [PR #2 (ematt)](https://github.com/jypma/skoda-manual/pull/2) plus:
- Interactive menu mode (`./skoda.sh` with no arguments)
- Automatic login with `USERNAME`/`PASSWORD`
- Cookie-based login alternative (`COOKIES`)
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
1. Login (from `.env` or typed in terminal)
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

Use a local `.env` file (recommended):

```bash
USERNAME=your@email.com
PASSWORD=your-password
```

Or export session cookies:

```bash
export COOKIES='JSESSIONID=abc123; BIGip...=...'
```

If you need to copy cookies manually:
1. Log in at [digital-manual.skoda-auto.com](https://digital-manual.skoda-auto.com)
2. Open DevTools (`F12`) and reload
3. Copy `Cookie:` from request headers

## Finding Manual ID

The manual ID is in the manual URL:

```text
https://digital-manual.skoda-auto.com/w/da_DK/show/b6c0b6d20c1b2988ac1445253a0f2c00_3_da_DK
                                                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

## Output Files

The script writes output files directly in the working directory:
- `manual.html` when HTML is selected
- `manual-standalone.html` when `--standalone` is selected
- `manual.pdf` when `--pdf` is selected

For non-standalone HTML, keep these next to `manual.html`:
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
| `ERROR: Incorrect username or password` | Invalid credentials | Verify your SKODA account login |
| `ERROR: No login credentials found` | No auth configured in non-interactive mode | Set `USERNAME`+`PASSWORD` or `COOKIES`, or run `./skoda.sh` |
| `ERROR: Interactive mode requires a terminal` | Interactive mode run in non-TTY environment | Run in a real terminal, or pass flags/manual ID |
| `ERROR: No PDF renderer found` | `--pdf` selected without renderer installed | Install Chromium, wkhtmltopdf, or WeasyPrint |
| Missing sections or images | Session expired or interrupted run | Rerun command (resume cache), preferably with `USERNAME`+`PASSWORD` |
