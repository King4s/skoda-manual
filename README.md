# skoda-manual

Download a ŠKODA digital owner's manual to local files (HTML, standalone HTML, and/or PDF).

No cookies, no login, no browser required. Provide your car's VIN or part number and the script handles everything automatically.

Based on [jypma/skoda-manual](https://github.com/jypma/skoda-manual), with fixes from [PR #2 (ematt)](https://github.com/jypma/skoda-manual/pull/2) plus:
- Automatic session creation via the Škoda entrypoint API (`importerId=004`)
- VIN or part number as input — no manual ID hunting required
- Interactive menu mode (`./skoda.sh` with no arguments)
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
1. Language selection
2. VIN or part number
3. Output format (HTML / PDF / standalone variants)

## Non-interactive Usage

Download a manual using a VIN:

```bash
./skoda.sh TMBZZZ3FZN1234567 da_DK --html
```

Download using a part number:

```bash
./skoda.sh 657012738AR da_DK --html
```

Download HTML + PDF:

```bash
./skoda.sh 657012738AR da_DK --html --pdf
```

Download standalone HTML (single file, no external assets):

```bash
./skoda.sh 657012738AR da_DK --standalone
```

Clear cache and start over:

```bash
./skoda.sh --clear-cache
```

## Finding Your VIN or Part Number

**VIN (recommended):** Found on your car registration documents, insurance papers, or on the dashboard visible through the windscreen. Always 17 characters, e.g. `TMBZZZ3FZN1234567`.

**Part number:** Found on [www.skoda.dk/apps/manuals/Models](https://www.skoda.dk/apps/manuals/Models) after selecting your model. Format: digits + letters, e.g. `657012738AR`.

## How It Works

1. The script POSTs your VIN or part number to `digital-manual.skoda-auto.com/api/entrypoint/V1/direct/` (the same endpoint the Škoda website uses)
2. The server creates an authenticated session
3. The script fetches the manual topic tree and all content via the session
4. HTML is assembled locally from the fetched JSON

## Output Files

Output filenames are auto-generated from the manual title:

`<Manual_Title>_<LANGUAGE>_<DD-MM-YYYY_HH-MM-SS>.ext`

Examples:
- `Scala_Owner_s_Manual_da_DK_23-02-2026_15-04-58.html`
- `Scala_Owner_s_Manual_da_DK_23-02-2026_15-04-58_standalone.html`
- `Scala_Owner_s_Manual_da_DK_23-02-2026_15-04-58.pdf`

For non-standalone HTML, keep these next to the `.html` file:
- `extra.css`
- `bootstrap.css`
- `images/`

## Resume Behavior

Downloaded content is cached in:
- `./cache` — JSON data and session
- `./images` — manual images

Rerun the same command to resume an interrupted download.

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `Session invalid` | VIN/part number not recognised | Double-check the VIN or use the part number from skoda.dk |
| `No manual found for this VIN/part number` | Language not available for this model | Try `en_GB` instead |
| `ERROR: Interactive mode requires a terminal` | Run in non-TTY environment | Run in a real terminal, or pass flags directly |
| `ERROR: No PDF renderer found` | `--pdf` selected without renderer | Install Chromium, wkhtmltopdf, or WeasyPrint |
| Missing sections or images | Interrupted run | Rerun the same command (cache resumes) |
