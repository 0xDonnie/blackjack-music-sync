# Authenticated YouTube access (advanced)

> **Heads-up:** this is an advanced setup with real caveats. The default sync script handles public and unlisted playlists without any of this. Only follow this guide if you actually need to sync content that requires being signed in: private playlists, members-only / Premium content, age-restricted videos.

## Why this is needed

By default, yt-dlp accesses YouTube anonymously. It can read public and unlisted playlists with no problem. But it cannot see:

- Videos marked **Private** by their uploader (only people the uploader explicitly shared the video with can see them — even logged-in users without explicit access cannot)
- **Members-only** / channel-membership content
- **Age-restricted** content that requires confirming an account
- Anything else that depends on a logged-in YouTube session

For yt-dlp to access these as you, it has to send YouTube the same login cookies your browser uses. The sync script supports two ways to provide those cookies. Both have downsides — read the section below before picking one.

## Important: "private" doesn't always mean "you can fix it"

Even with cookies set up correctly, a video that the uploader has marked Private and never explicitly shared with your account is still inaccessible. yt-dlp will authenticate successfully, then YouTube will reply *"this video is private"*. There is nothing this tool can do about that — only the uploader can grant access. Cookies fix the "I'm not signed in" case, not the "I'm not allowed" case.

---

## Option 1 — Read cookies directly from a browser

The sync script forwards the `--cookies-from-browser` flag to yt-dlp if you set the `$COOKIES_FROM_BROWSER` variable in `config.ps1`.

### Supported browsers

yt-dlp natively supports Firefox, Chrome, Chromium, Edge, Brave, Vivaldi, Opera, and Safari (macOS only). For these you can just write the browser name:

```powershell
$COOKIES_FROM_BROWSER = "firefox"
```

For a Chromium-based browser that yt-dlp doesn't know about (e.g. Comet, Arc, Thorium), you can pass a custom profile directory after a colon. yt-dlp will read it as a generic Chromium profile:

```powershell
$COOKIES_FROM_BROWSER = "chrome:C:\Users\YOU\AppData\Local\Perplexity\Comet\User Data\Default"
```

### The big catch on Windows

On Windows, **Chromium-based browsers hold an exclusive lock on the cookie SQLite database while they are running**. That means yt-dlp cannot read the cookies if your browser is open. You will get an error like:

```
PermissionError: [Errno 13] Permission denied: '...\Network\Cookies'
yt_dlp.utils.DownloadError: Could not copy Chrome cookie database
```

You have to fully close the browser — including any background processes that linger after you close the window — before each sync run. Firefox does not have this limitation; it lets multiple readers open the cookie file at once.

If you can't or don't want to close the browser, use Option 2.

### Setup steps

1. Find your browser's profile directory. For Chromium browsers it's typically under `%LOCALAPPDATA%\<vendor>\<browser>\User Data\<profile>`. The `<profile>` is usually `Default`, but if you have multiple profiles you'll see `Profile 1`, `Profile 2`, etc.
2. Open `config.ps1` and set `$COOKIES_FROM_BROWSER`:
   ```powershell
   $COOKIES_FROM_BROWSER = "firefox"
   # or
   $COOKIES_FROM_BROWSER = "chrome:C:\path\to\profile"
   ```
3. Make sure `$COOKIES_FILE` stays empty.
4. Before running a sync, close your browser completely (Chromium browsers only).

---

## Option 2 — Export cookies to a `cookies.txt` file

You export your YouTube cookies once with a browser extension, save them to a file, and point the sync script at that file. The browser can stay open while the sync runs because the script reads the file you exported, not the live browser database.

The downside: cookies expire eventually. YouTube session cookies typically last weeks to a few months, but when they expire you'll have to re-export.

### Setup steps

1. Open your browser (any Chromium-based browser will do — Comet works since it accepts Chrome extensions).
2. Install the extension **"Get cookies.txt LOCALLY"** from the Chrome Web Store. Do not install the older "Get cookies.txt" — it was pulled for privacy concerns; "LOCALLY" is the maintained replacement.
3. Visit https://www.youtube.com and make sure you are signed in.
4. Click the extension's icon in the toolbar and export the YouTube cookies. The format you want is **Netscape**.
5. Save the resulting `cookies.txt` file somewhere private. It is recommended to put it **outside** the repo so you can't accidentally commit it. Example:
   ```
   C:\Users\YOU\blackjack-cookies.txt
   ```
6. Open `config.ps1` and set `$COOKIES_FILE` to that path:
   ```powershell
   $COOKIES_FILE = "C:\Users\YOU\blackjack-cookies.txt"
   ```
7. Make sure `$COOKIES_FROM_BROWSER` stays empty.

### Security warning

`cookies.txt` contains live session tokens. Anyone who reads that file can sign in to YouTube as you. Treat it like a password:

- Do not commit it to git. The repo's `.gitignore` already excludes `cookies.txt`, but to be safe keep the file outside the repo entirely.
- Do not share it.
- Re-export it if you suspect it leaked.

---

## When the cookies have expired

Symptoms: yt-dlp suddenly stops downloading authenticated content and starts reporting "Sign in to confirm your age" or "This video requires payment" or "Private video" for content that worked yesterday.

For Option 1, just close your browser and run the sync again — yt-dlp will read fresh cookies from the live browser session.

For Option 2, re-run the export step from the extension. Save over the existing `cookies.txt`.

---

## Verifying it works

Run a sync (`Sync All` from the GUI, or `.\sync_playlists_v1.ps1` from PowerShell). In the log you should see one of these lines right before the yt-dlp output for each playlist:

```
Using cookies from browser: chrome:C:\path\to\profile
```
or
```
Using cookies file: C:\path\to\cookies.txt
```

If you don't see either, the variable is empty or unreadable. Double-check `config.ps1` and try again.
