# skoda-manual

Download a ŠKODA digital owner's manual to local files (HTML, standalone HTML, and/or PDF).

No cookies, no login, no browser required. Provide your car's VIN or part number and the script handles everything automatically.

Available for **Linux/macOS** (`skoda.sh`) and **Windows** (`skoda.bat` + `skoda.ps1`).

Based on [jypma/skoda-manual](https://github.com/jypma/skoda-manual), with fixes from [PR #2 (ematt)](https://github.com/jypma/skoda-manual/pull/2) plus:
- Automatic session creation via the Škoda entrypoint API (`importerId=004`)
- VIN or part number as input — no manual ID hunting required
- Interactive menu mode
- Resume support with caching in `./cache` and `./images`
- PDF output support (Linux: Chromium/wkhtmltopdf/WeasyPrint)

---

## Linux / macOS

### Requirements

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

### Quick Start (Interactive)

```bash
./skoda.sh
```

### Non-interactive

```bash
./skoda.sh 657012738AR da_DK --html
./skoda.sh TMBZZZ3FZN1234567 da_DK --html
./skoda.sh 657012738AR da_DK --html --pdf
./skoda.sh 657012738AR da_DK --standalone
./skoda.sh --clear-cache
```

---

## Windows

### Requirements

- Windows 10 or later (PowerShell 5.1 is included)
- No additional installs needed

### Quick Start (Interactive)

Double-click **`skoda.bat`**.

The batch file checks that PowerShell is available and at least version 5.1, then launches `skoda.ps1` with the correct execution policy so Windows does not block it.

### Non-interactive (PowerShell)

```powershell
.\skoda.ps1 657012738AR da_DK -Html
.\skoda.ps1 TMBZZZ3FZN1234567 da_DK -Html
.\skoda.ps1 657012738AR da_DK -Standalone
.\skoda.ps1 -ClearCache
.\skoda.ps1 -Help
```

Or via the batch file:

```cmd
skoda.bat 657012738AR da_DK -Html
```

---

## Finding Your VIN or Part Number

**VIN (recommended):** Found on your car registration documents, insurance papers, or on the dashboard visible through the windscreen. Always 17 characters, e.g. `TMBZZZ3FZN1234567`.

**Part number:** Found on [www.skoda.dk/apps/manuals/Models](https://www.skoda.dk/apps/manuals/Models) after selecting your model. Format: digits + letters, e.g. `657012738AR`.

## How It Works

1. The script POSTs your VIN or part number to `digital-manual.skoda-auto.com/api/entrypoint/V1/direct/` (the same endpoint the Škoda website uses, with `importerId=004`)
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
| `Interactive mode requires a terminal` | Run in non-TTY environment | Run in a real terminal, or pass arguments directly |
| `No PDF renderer found` | `--pdf` used without a renderer installed | Install Chromium, wkhtmltopdf, or WeasyPrint |
| `running scripts is disabled` (Windows) | PowerShell execution policy blocks scripts | Use `skoda.bat` instead of running `.ps1` directly |
| Missing sections or images | Interrupted run | Rerun the same command (cache resumes) |
