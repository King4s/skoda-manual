# skoda-manual

Downloads a ŠKODA digital owner's manual as a single self-contained HTML file with local images.

Based on [jypma/skoda-manual](https://github.com/jypma/skoda-manual), with fixes from [PR #2 (ematt)](https://github.com/jypma/skoda-manual/pull/2) and additional improvements:
- Automatic login with username/password (no manual cookie copying needed)
- `set +H` fix for bash history expansion
- Caching of all downloaded content for resumable runs
- Correct handling of the current image URL format

## Requirements

```bash
sudo apt install curl jq libxml2-utils
```

## Usage

### Option 1 — Automatic login (recommended)

```bash
cd /opt/skoda-manual

export USERNAME='your@email.com'
export PASSWORD='your-password'

./skoda.sh <MANUAL_ID> <LANGUAGE> > manual.html
```

Example for a Danish manual:

```bash
./skoda.sh b6c0b6d20c1b2988ac1445253a0f2c00_3_da_DK da_DK > manual.html
```

### Option 2 — Manual cookie

If automatic login does not work, you can copy cookies from your browser.

1. Go to [digital-manual.skoda-auto.com](https://digital-manual.skoda-auto.com) and log in
2. Open DevTools (`F12`) → **Network** tab → reload the page
3. Click any request to the site → **Request Headers** → copy the `Cookie:` value

```bash
export COOKIES='JSESSIONID=abc123; BIGip...=...'
./skoda.sh b6c0b6d20c1b2988ac1445253a0f2c00_3_da_DK da_DK > manual.html
```

## Finding your manual ID

The manual ID is in the URL when you browse the manual online:

```
https://digital-manual.skoda-auto.com/w/da_DK/show/b6c0b6d20c1b2988ac1445253a0f2c00_3_da_DK
                                                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                                    This is your manual ID
```

## Resuming an interrupted download

All fetched content is cached in `./cache/` and images in `./images/`. Re-running the script skips already-downloaded files automatically.

## Output

The script outputs HTML to stdout and progress messages to stderr, so redirect appropriately:

```bash
./skoda.sh <MANUAL_ID> <LANGUAGE> > manual.html          # HTML to file, progress to terminal
./skoda.sh <MANUAL_ID> <LANGUAGE> > manual.html 2>log.txt  # both to files
```

The generated `manual.html` requires `extra.css`, `bootstrap.css`, and the `images/` folder to be in the same directory.

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `ERROR: Incorrect username or password` | Wrong credentials | Check your ŠKODA ID login |
| `ERROR: No login credentials found` | No env vars set | Set `USERNAME`+`PASSWORD` or `COOKIES` |
| Empty sections / missing content | Session expired | Log in again (re-run with credentials) |
| Missing images | Download interrupted | Re-run the script — it resumes automatically |
