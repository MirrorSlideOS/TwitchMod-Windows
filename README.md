# 🦇 TwitchMod for Windows

A Windows Twitch chat moderation tool with a double-clickable `TwitchMod.exe` launcher, live chat monitoring, and an editable CSV word/phrase dictionary. The launcher runs the included PowerShell script. **This is not yet a self-contained native app, and live Twitch moderation has not been verified.**

## Features

- Watch messages in a Twitch channel through Twitch IRC over WebSocket.
- Delete an individual message (using its Twitch message ID), timeout a user, or ban a user.
- Optional automatic moderation using words or full phrases from `rules.csv`.
- Matching modes: `contains`, `wholeword`, `exact` (case-insensitive).
- Configurable timeout durations and optional local chat logs.
- Automatic moderation starts **off** and example rules start **disabled**.
- Local login tokens protected with Windows DPAPI for the current Windows user.

## Download and install

1. On GitHub, open **Releases** and download the Windows ZIP, if one has been published. Otherwise choose **Code → Download ZIP** for the repository files.
2. Extract the ZIP to a normal folder (do not launch from inside the ZIP).
3. Open `config.json` in Notepad and replace `PASTE_YOUR_TWITCH_CLIENT_ID` and `YOUR_CHANNEL_NAME`.
4. Register a **Public** application at [Twitch Developer Console](https://dev.twitch.tv/console/apps) to obtain your Client ID. **Never paste your Twitch Client Secret into this project.**
5. Double-click `TwitchMod.exe`. Complete Twitch device authorization in your browser.
6. The signed-in Twitch account must be the channel owner or an appointed moderator to perform actions.
7. Edit `rules.csv` and press **R** in the app to reload enabled rules. Press **A** to toggle automatic enforcement.

> **Windows requirement:** Windows 10/11 with Windows PowerShell 5.1. SmartScreen may warn about an unsigned executable; only run binaries from a source you trust. The EXE is an *unsigned launcher* and expects `TwitchMod.ps1` alongside it. The `src/` copy is provided for review; don't delete the root script.

## Dictionary format

```csv
Enabled,Action,Seconds,Match,Pattern
false,timeout,600,contains,example spam phrase
false,ban,0,wholeword,examplebannedword
false,delete,0,contains,example unwanted sentence
```

- `Enabled`: set to `true` to activate the rule.
- `Action`: `delete`, `timeout`, or `ban`.
- `Seconds`: between `1` and `1209600` for `timeout`; ignored for other actions.
- `Match`: `contains`, `wholeword`, or `exact`.
- `Pattern`: text to match. If it contains commas, surround it with CSV quotation marks.
- **Order matters:** the first matching enabled rule is applied. Put stricter rules first if desired.

## Keyboard controls

| Key | Action |
| --- | --- |
| `A` | Turn automatic moderation on/off for the current session |
| `R` | Reload dictionary rules from disk |
| `D` | Delete a selected recent message |
| `T` | Timeout a selected user |
| `B` | Ban a selected user |
| `Q` | Quit |

Manual actions require selecting a message number, and ask for confirmation. The on-screen indices refer to the current rolling list of 50 messages.

## Security and privacy

- **Do not commit** `twitch_tokens.dpapi` or `chat.log`, or any real account credentials. `.gitignore` excludes them.
- `config.json` may contain a personally identifying channel name or your public app Client ID. Review it before you publish your fork. Client IDs aren't passwords, but avoid unintentionally exposing personal settings.
- Twitch permissions requested: `chat:read`, `moderator:manage:chat_messages`, and `moderator:manage:banned_users`.
- Enabling automatic bans/timeouts applies real moderation actions to your channel. Test gently with a private channel before using it publicly.
- `log_chat_locally` is `false` by default.

## Known limitations

- Not tested end-to-end on Windows or with a live Twitch channel. GitHub repository packaging does **not** establish that it works in production.
- The EXE needs the adjacent PowerShell script; it is not a single-file binary.
- This version uses Twitch IRC chat, and does not have a graphical dashboard, auto reconnect, or comprehensive rate-limit handling.
- Rules can match innocent uses of words or quotes; review patterns before enabling automation.
- The EXE included here is prebuilt and unsigned, without a reproducible Windows build recipe. Consider rebuilding and signing it yourself before distributing widely.

## Publishing to GitHub

1. Create a **public repository** on GitHub, such as `twitchmod-windows`.
2. Upload the contents of this folder (not the outer ZIP), or push them using Git.
3. Review every changed file for private information before publishing.
4. To provide an easy download, create a GitHub **Release** and attach a ZIP containing `TwitchMod.exe`, `TwitchMod.ps1`, `config.json`, and `rules.csv`.
5. Add a release note stating that this is an **unsigned, unverified preview**.

See [Twitch's moderation documentation](https://dev.twitch.tv/docs/chat/moderation/) and [OAuth documentation](https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/) for API authorization details.

## License

MIT, see [LICENSE](LICENSE). This project is not affiliated with or endorsed by Twitch.
