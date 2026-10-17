# Signel security fixes: design

Date: 2026-10-17
Fork: https://github.com/twillis209/signel (upstream: keenban/signel)

## Intent

Signel is a small Emacs front end for Signal that talks to a `signal-cli`
daemon over JSON-RPC (`signel.el`, one file, ~640 lines). A read-only security
review found that it handles untrusted incoming data in risky ways. The owner
wants to fix those issues first, then add features (starting with easier image
sending, e.g. pasting a clipboard image) on top. This design covers only the
security fixes.

The fork is personal for now; no upstream PRs. It must keep working on both
macOS (main machine: emacs-plus 30.2, NS build, no D-Bus) and Linux (the owner
will set it up there too).

## Goals

1. Received images are shown inline straight away *when it is reasonably safe*,
   and otherwise behind a click.
2. Nothing a sender controls can run code or open files without an explicit,
   informed action by the owner.
3. A malformed message can never break the chat buffer or the prompt.
4. The owner can trust what the UI says: who sent a message, and whether a sent
   message actually got through.
5. Notifications work on macOS and keep working on Linux.

## Non-goals

- Clipboard image sending and other new features (next design).
- Persisting chat history or a contact list UI.
- Fixing `signal-cli` behaviour, e.g. attachments from disappearing messages
  being kept forever.
- Upstreaming.

## Anti-goals

- Anything that interpolates message text, sender names, filenames or IDs into
  a shell command or AppleScript source.
- Making the client noticeably more annoying for normal chats with known people
  (e.g. confirming every image from a contact).
- Breaking Linux support while fixing macOS.

## Background: findings being fixed

Line numbers refer to `signel.el` at commit 5b309dd.

| # | Finding | Where |
|---|---------|-------|
| F1 | Any sender's images/stickers are decoded immediately; decoder chosen by file header, gate is the sender-supplied MIME type | `signel--insert-media` 350-435 |
| F2 | `[File: ...]` buttons pass sender-named files to `browse-url-of-file` → macOS `open`; sender controls extension; bidi chars can disguise the name; no quarantine attribute | 413-414, 428-430 |
| F3 | An error while rendering a message (nil `contentType`, unknown image type, bad sticker) aborts after the prompt was deleted, leaving the input marker inside the sender's text | `signel--insert-msg` 486-517 |
| F4 | Notifications call `notifications-notify` (D-Bus), which errors on macOS; the error also stops `signel-auto-open-buffer` from working | 280-290 |
| F5 | Display name is the sender's self-chosen profile name; no number shown in chat; may contain newlines/bidi/`%`-constructs (used unescaped in `mode-line-process`) | 272, 301, 506 |
| F6 | Local echo "Me: ..." is inserted before any reply; `result` replies are ignored, so partial group-send failures are invisible | 230-238, 537-571 |
| F7 | Animated images loop forever (`image-animate ... t`) | 387, 410, 427 |
| F8 | ImageMagick `convert` runs on received APNG stickers (argv, no shell: OK; still a decoder on untrusted input) | 330-348 |
| F9 | Every RPC line, including full message text, is logged to `*signel-log*` | 131-137, 195, 218 |
| F10 | Process is a pty with stderr merged into stdout; 100 KB cap is applied before splitting lines, so one big line discards good ones | 147-172, 201-222 |

Verified non-issues (keep it that way): RPC params are built with
`json-encode`; no shell, `osascript` or `eval` anywhere; no path traversal
(signal-cli sanitises IDs); stdio JSON-RPC, no TCP listener.

## Decisions made with the owner

### Incoming images (F1, F7, F8)

- **Known contact + allowed format → shown inline straight away.**
  - "Known contact" = the sender's number is in the contact list `signal-cli`
    holds (synced from the phone). Signel should fetch it at start-up via the
    JSON-RPC `listContacts` method and keep it in memory; refreshing it later
    is the builder's call.
  - *Designer's call:* a `listContacts` entry counts only if it has a name the
    owner saved (address-book or Signal contact name, not just a profile name)
    and is not blocked. Match the sender on UUID as well as number, since
    `sourceNumber` is often missing. If no contact list is available, nobody is
    "known" and every image gets a button.
  - *Designer's call:* messages that arrive before the `listContacts` reply are
    queued and processed once it arrives, or after a short timeout (a few
    seconds), after which they are processed with whatever list exists.
  - "Allowed format" = PNG, JPEG or GIF, decided by sniffing the file's actual
    bytes (`image-type-from-file-header` or equivalent), never by the
    sender-supplied `contentType`.
- **Anyone else, or any other format (SVG, WebP, TIFF, HEIC, XPM, ...)** → a
  `[Show image]` button; clicking renders it. Group messages: the rule applies
  to the individual sender, not the group.
- **Stickers** follow the same rules, with one exception the owner chose:
  WebP stickers from known contacts are also shown straight away (almost all
  Signal stickers are WebP). WebP *attachments* still need a click. Animated
  (APNG) stickers from unknown senders are not converted with ImageMagick
  until clicked.
- **Animations** play a bounded number of times / bounded duration (respect
  `image-animate-max-time` or similar), never forever.
- A user option should let the owner turn auto-display off entirely.

### Rendering robustness (F3)

- Rendering of each message (text, media, sticker) is wrapped so that any error
  shows `[Couldn't display ...]` in place and is logged.
- The prompt and input marker are always restored (`unwind-protect`), whatever
  happens.
- One bad envelope must not stop the rest of `signel--handle-receive` (sync
  messages, typing indicators, other parts of the same message).

## Decisions made by the designer (owner accepted the summary in chat)

### Received files (F2)

- Button label shows the sanitised filename: control and bidi characters
  removed, and the real on-disk extension shown explicitly.
- Clicking asks `y-or-n-p` naming the file and its real extension before
  opening.
- On macOS, set the `com.apple.quarantine` extended attribute on the file (via
  `xattr`, argv only) before opening, so Gatekeeper treats it as downloaded.
  On Linux, no equivalent; the confirmation is the safeguard.

### Sending (F6)

- Local echo is shown as pending ("sending…") until the matching JSON-RPC
  reply arrives; then marked sent, or failed with the reason.
- For group sends, per-recipient failures in the `result` are reported in the
  chat (which members did not get it).
- This needs a table from RPC id → callback/marker; `signel--dispatch` must
  handle `result` messages.

### Notifications (F4)

- macOS: native notifications without D-Bus. The mechanism is the builder's
  call (e.g. `osascript` with the text passed as `argv` to an `on run argv`
  script, or `terminal-notifier` if installed), with the hard rule that no
  message, name or ID text is ever placed in script source or a shell string.
- Linux: keep `notifications-notify`.
- If notifications fail for any reason, the failure is caught and logged, and
  auto-opening the chat buffer still happens.

### Sender identity (F5)

- *Designer's call:* when the sender is a known contact, show the name the
  owner saved for them (from `listContacts`), not their self-chosen profile
  name. Otherwise show the sanitised profile name plus the number (or a short
  UUID if there is no number). In group chats, always show the number too. The
  same name source is used by the dashboard.
- Display names are sanitised: newlines, control and bidi characters removed;
  `%` escaped before going into `mode-line-process`. The typing indicator
  should also be cleared when typing stops.

### Logging (F9)

- By default the log records RPC traffic without message bodies (method, id,
  sizes, errors). A user option turns full logging back on for debugging.
- Attachment payloads (future base64 `data:` URIs) must never be logged in
  full.

### Process plumbing (F10)

- Start `signal-cli` with `:connection-type 'pipe` and a separate `:stderr`
  buffer/process.
- Split incoming data into lines first, then apply any size cap per line.

## Constraints

- Emacs 27.1+ remains the declared minimum unless a fix truly needs newer; if
  so, say so in the package header.
- Keep it a single-file package with no new hard dependencies. External tools
  (`xattr`, `osascript`, `terminal-notifier`, ImageMagick) are optional and
  called via `call-process`/`make-process` with argv lists, never a shell.
- Must not break: sending text, receiving text, groups, attachments, stickers,
  dashboard, existing user options.
- Must work on macOS NS builds without D-Bus and on Linux builds with D-Bus.

## Left to the builder

- Code structure, naming of new functions and user options.
- Exact wording of buttons and messages.
- How often to refresh the contact list.
- Choice of macOS notification mechanism within the rules above.
- Testing approach. The repo has no tests today; ERT tests for the pure parts
  (format sniffing, name sanitising, the contact/format decision, line
  splitting, result handling) are expected. End-to-end checks against a live
  `signal-cli` need the owner present, because they send real messages.
- Commit granularity (one commit per finding is a reasonable default).
