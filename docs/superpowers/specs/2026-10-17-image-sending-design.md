# Signel image sending: design

Date: 2026-10-17
Fork: https://github.com/twillis209/signel
Builds on: `docs/superpowers/specs/2026-10-17-security-fixes-design.md` (merged)

## Intent

The owner wants sending images from Emacs to be as easy as on the phone. The
images come from two places: **files on disk** and **the clipboard** (e.g. a
screenshot or a copied picture). They want to **add a caption**, and sometimes
to **send several images in one message**.

Today the only way is `C-c C-a` (`signel-attach-file`), which sends one file
immediately, without a caption, and shows only `[Sending: name]`.

## Goals

1. Paste an image from the clipboard into a chat with the normal paste key.
2. Attach image files (and other files) from disk.
3. Queue several attachments, add an optional caption, send them together in
   one message.
4. See what will be sent, and to whom, before anything leaves.
5. Don't leak location or camera data from photos.
6. After sending, see the owner's own images in the chat.
7. Work on macOS (main machine) and Linux.

## Non-goals

- Editing/cropping images, drag-and-drop, sending video previews.
- Downloading or browsing past media.
- Changing how *received* images are handled (covered by the security design).

## Anti-goals

- Sending anything the owner didn't explicitly confirm by pressing `RET`
  (e.g. a paste that sends straight away, or the wrong clipboard contents).
- Pasting text breaking: when the clipboard holds text, paste must behave
  exactly as before.
- Leaving copies of the owner's images lying around in temp directories.
- Breaking any of the security fixes: no shell commands, no message/file data
  in command strings, logs must never contain image data.

## The experience (decided with the owner)

### Pending attachments

- Pasting an image, or `C-c C-a` on a file, **adds a pending attachment**
  instead of sending.
- Pending attachments are shown in a row **just above the prompt**: images as
  small thumbnails, other files by name, labelled with the recipient (e.g.
  `To Mum (+447…): [thumb] [thumb] report.pdf`). This row is the preview; there
  is no separate "Send this?" question.
- The owner types an optional caption at the prompt as normal.
- `RET` (and `C-c C-c`) sends all pending attachments plus the caption as
  **one** Signal message. With pending attachments, an empty caption is fine.
- After sending, the owner's message line shows the caption and the images
  (rendered from the data that was sent, not re-read from disk), with the
  existing `(sending…)` status behaviour.
- Pending attachments belong to one chat buffer; they are not shared between
  chats.

### When a send fails (designer's call)

- If the whole send fails (RPC error), the attachments and the caption are put
  back as pending in that chat (unless the owner has already started a new
  draft there, in which case the old ones are appended to the pending row and
  the caption isn't restored), so retrying is just `RET` again.
- On partial delivery failure (some group members didn't get it), nothing is
  restored; the existing "(not delivered to: …)" status shows who missed it.

### Removing pending attachments (designer's call)

- `C-c C-k` removes the most recently added pending attachment.
- `C-u C-c C-k` removes all of them.
- Killing the chat buffer discards them.

### Pasting (designer's call on mechanism)

- In a chat buffer, the paste commands the owner actually uses check the
  clipboard first. The owner uses Spacemacs in **vim (evil) style**, so this
  must cover evil's paste commands (`p`/`P` in normal state, `C-y`/`C-r`-style
  paste in insert state) as well as plain `yank` (`C-y`). If the clipboard
  holds an image, it becomes a pending attachment; otherwise the original
  paste command runs unchanged.
- Images are read from the clipboard without a shell:
  1. Emacs's own clipboard API first (e.g. `gui-get-selection` with an image
     type such as `image/png`; Emacs 30 NS build here supports image
     clipboard data — verify interactively).
  2. Fallback on macOS: `pngpaste -` (installed at `~/opt/bin/pngpaste`).
  3. Fallback on Linux: `wl-paste --type image/png` on Wayland, `xclip
     -selection clipboard -t image/png -o` on X11.
  External tools are optional and run via `call-process`/`make-process` with
  argv lists.
- *Designer's call — which paste wins:* if the clipboard holds an image, the
  image wins. This can't pick up a stale screenshot by accident, because
  Emacs (and Spacemacs's evil yank) writes every kill/yank to the system
  clipboard, so the clipboard always holds the most recent copy from either
  side. Commands covered: `yank` (`C-y`, and `s-v`/Cmd-V on macOS, which
  call `yank`), `evil-paste-after` (`p`), `evil-paste-before` (`P`). Evil
  pastes from a named register (`"ap`) are left alone.
- A pasted image gets a filename like `clipboard-YYYYMMDD-HHMMSS.png` (the
  name the recipient sees).

### Files from disk (designer's call)

- `C-c C-a` keeps its key and prompts for a file as now, but adds a pending
  attachment instead of sending. Any file type is allowed; image files get a
  thumbnail, others show their name.
- Files are read when they're added (so the preview shows what will be sent),
  and the original filename is kept.

## Safety and privacy (designer's calls, owner accepted in chat)

- **Metadata:** JPEG/PNG/HEIC/WebP images are cleaned before sending
  (location, camera, timestamps). Mechanism: ImageMagick (`magick` or
  `convert`, `-strip`, argv only, data via stdin/stdout or a private temp file
  deleted straight after). Screenshots/clipboard PNGs go through the same path.
  If an image can't be cleaned (no ImageMagick, or it fails), the pending
  item shows a warning (e.g. `⚠ location data not removed`) and `RET` asks
  once "Some images still contain metadata. Send anyway?" before sending.
  Non-image files are sent unchanged (and the owner knows that).
  *Designer's calls:* run `-auto-orient` before `-strip` so phone photos
  aren't sent sideways. GIFs are sent unchanged without a warning (they carry
  no location data in practice). HEIC is converted to JPEG when ImageMagick
  can read it (filename and MIME change to `.jpg`/`image/jpeg`); otherwise it
  is sent unchanged with the warning.
- **Decoding:** these are the owner's own images, so rendering thumbnails is
  fine, but only for types the security design already allows inline (PNG,
  JPEG, GIF, WebP); anything else shows as a file name. Sniff types from
  bytes, as in the security design.
- **Transport:** send attachments to signal-cli as data URIs
  (`data:<mime>;filename=<name>;base64,<data>`), supported by signal-cli's
  `send` `attachments` parameter, so no temp file has to outlive the send.
  The MIME type comes from the sniffed bytes, not the file extension.
  *Designer's call:* for files that don't sniff as one of the known image
  types, use the extension's MIME type (e.g. via `mailcap-extension-to-mime`),
  falling back to `application/octet-stream`. That only affects how the
  recipient's app labels the file.
- **Logging:** `signel--log-summary` already abbreviates `data:` URIs to
  `data:<N bytes>`; keep it that way and add a test for multi-attachment
  sends.
- **Size:** refuse to add an attachment larger than a user option
  (`signel-max-attachment-size`, default 100 MB, Signal's own limit) with a
  clear message.
- **Recipient confidence:** the pending row always names the recipient as
  `signel--display-name` shows them.

## Constraints

- Emacs 27.1+ unless a feature truly needs newer (clipboard image APIs may;
  if so, degrade to the external-tool fallbacks rather than raising the
  minimum).
- Single-file package; no new hard dependencies. `pngpaste`, `wl-paste`,
  `xclip`, ImageMagick are optional.
- No shell; argv only. No test may start signal-cli or send a message.
- Keep all existing behaviour and the 73 existing tests passing.

## Left to the builder

- How the pending row is drawn (overlay vs read-only text) and thumbnail size.
- Exact wording of labels and messages.
- Function and option names (beyond `signel-max-attachment-size`).
- How evil integration is done (e.g. `evil-define-key` in the chat mode,
  guarded with `with-eval-after-load 'evil`, or command remapping), as long as
  text paste is unchanged.
- Testing approach: ERT for the pure parts (clipboard source selection with
  stubs, data-URI building, metadata-strip command argv, pending-list
  operations, the send params for several attachments + caption). A live
  check with the owner at the end (paste a screenshot, attach two files with a
  caption, check the recipient sees them and that a photo's location data is
  gone).
