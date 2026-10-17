# Signel Image Sending Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the owner queue images (pasted from the clipboard or picked from disk) and other files in a chat, add a caption, and send them together as one message, with photo metadata removed.

**Architecture:** An attachment is a plist built from bytes in memory (name, MIME type, sniffed image type, bytes, whether metadata was cleaned). Each chat buffer keeps a list of pending attachments, drawn as an overlay row just above the prompt. Paste commands are remapped in chat buffers to queue a clipboard image, or else run the normal paste. `RET` sends the caption plus the attachments as `data:` URIs in one `send` request, and the echo line renders the owner's own images from memory.

**Tech Stack:** Emacs Lisp (lexical binding, Emacs 27.1+), ERT, signal-cli 0.14.9 JSON-RPC (`send` with `attachments` as data URIs), optional ImageMagick, `pngpaste`, `wl-paste`, `xclip`.

**Spec:** `docs/superpowers/specs/2026-10-17-image-sending-design.md`

## Global Constraints

- `Package-Requires: ((emacs "27.1"))` stays; newer clipboard APIs are used only when present (`fboundp`), degrading to the external tools.
- Single-file package; no new hard dependencies. External tools are optional and run via `call-process` / `call-process-region` with argv lists. Never a shell, never file names or message data in a command string.
- No test may start signal-cli or any real external process, or send a Signal message. Stub with `cl-letf`.
- Logs never contain image bytes or base64: `signel--log-summary` must keep abbreviating `data:` URIs.
- Text paste must behave exactly as before when the clipboard has no image.
- Nothing is sent until the owner presses `RET` (or `C-c C-c`) in the chat.
- All 73 existing tests keep passing; `signel.el` byte-compiles with no warnings.
- `signel-max-attachment-size` default `104857600` (100 MB).

**Commands** (from `~/projects/signel`):

```bash
EMACS=~/Applications/emacs.noindex/Emacs.app/Contents/MacOS/Emacs   # ~/opt/bin/emacs wrapper is broken
$EMACS -Q --batch -L . -l test/signel-test.el -f ert-run-tests-batch-and-exit
$EMACS -Q --batch -L . -l test/signel-test.el --eval '(ert-run-tests-batch-and-exit "NAME-REGEXP")'
$EMACS -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile signel.el && rm -f signel.elc
```

Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Clipboard holds text, or no clipboard tool is installed.** `C-y`/`p`/`P` must paste text exactly as before, with no error. (Test in Task 3.)
2. **The owner presses `RET` with attachments queued and no caption.** It must send (today an empty input does nothing). (Test in Task 5.)
3. **A file name containing `;`, `,`, `%`, spaces or non-ASCII.** The data URI must stay well-formed and the recipient should still see a sensible name. (Test in Task 1.)
4. **ImageMagick is missing or fails, and the owner declines "Send anyway?".** Nothing is sent, and the pending items and caption stay as they were. (Test in Task 5.)
5. **Pasting while point is up in the chat history** (above the prompt, in evil normal state). The image is still queued for this chat and history isn't modified. (Test in Task 3.)

---

### Task 1: Attachments in memory and data URIs

**Files:**
- Modify: `signel.el` (Configuration: new defcustom; new section `;;; Outgoing Attachments` after `;;; Media & Stickers`)
- Test: `test/signel-test.el`

**Interfaces:**
- Produces: `defcustom signel-max-attachment-size` (integer bytes, default 104857600).
- Produces: `(signel--make-attachment NAME BYTES) -> plist` with keys `:name` (`signel--sanitize-name` of NAME's base name, then `/` and `\` replaced by `_`; everything else, including non-ASCII, is kept, since Task 1's data URI percent-encodes it), `:bytes` (unibyte string), `:image-type` (`signel--sniff-image-buffer` result on BYTES, or nil), `:mime` (`png`→`image/png`, `jpeg`→`image/jpeg`, `gif`→`image/gif`, `webp`→`image/webp`, `heic`→`image/heic`; otherwise `mailcap-extension-to-mime` of the name's extension, else `application/octet-stream`), `:clean` (nil; set by Task 2). Signals `user-error` mentioning the size limit if `(length BYTES)` exceeds `signel-max-attachment-size`.
- Produces: `(signel--attachment-data-uri ATT) -> string`: `data:MIME;filename=NAME;base64,B64`, where NAME is `url-hexify-string` of `:name` and B64 is `base64-encode-string` of `:bytes` with NO-LINE-BREAK t.
- Produces: `(signel--read-file-bytes FILE) -> unibyte string` via `insert-file-contents-literally`; checks the size with `file-attribute-size` before reading and signals the same `user-error` when too big.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-make-attachment-sniffs-and-maps-mime ()
  (let ((att (signel--make-attachment "x.dat" (unibyte-string #x89 ?P ?N ?G ?\r ?\n #x1a ?\n))))
    (should (eq (plist-get att :image-type) 'png))
    (should (equal (plist-get att :mime) "image/png"))))
(ert-deftest signel-make-attachment-non-image-uses-extension ()
  (should (equal (plist-get (signel--make-attachment "r.pdf" "%PDF-1.7") :mime) "application/pdf"))
  (should (equal (plist-get (signel--make-attachment "r.zzz" "abc") :mime) "application/octet-stream")))
(ert-deftest signel-attachment-data-uri-is-well-formed ()
  (let ((uri (signel--attachment-data-uri
              (signel--make-attachment "a;b,c%d Zoë.txt" "hi"))))
    (should (string-prefix-p "data:text/plain;filename=" uri))
    (should (string-suffix-p ";base64,aGk=" uri))
    ;; exactly one comma, and no extra ';' before ";base64"
    (should (= 1 (cl-count ?, uri)))
    (should (string-match-p "\\`data:[^;]+;filename=[^;,]+;base64," uri))))
(ert-deftest signel-make-attachment-size-limit ()
  (let ((signel-max-attachment-size 3))
    (should-error (signel--make-attachment "x" "abcd") :type 'user-error)))
```

- [ ] **Step 2: Run, expect FAIL** (void functions).
- [ ] **Step 3: Implement.** `(require 'mailcap)` and `(require 'url-util)` at the top (both ship with Emacs).
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Build outgoing attachments in memory as data URIs`.

### Task 2: Metadata cleaning

**Files:**
- Modify: `signel.el` (`;;; Outgoing Attachments`)
- Test: `test/signel-test.el`

**Interfaces:**
- Consumes: `signel--make-attachment` plist (Task 1).
- Produces: `(signel--imagemagick-program) -> string or nil`: `magick` if `executable-find`s, else `convert`, else nil.
- Produces: `(signel--clean-attachment ATT) -> ATT'` (a new plist):
  - `:image-type` `jpeg`, `png` or `webp` → bytes piped through ImageMagick with argv `(TYPE":-" "-auto-orient" "-strip" TYPE":-")` (with `magick`, the argv is the same list), via `call-process-region` on a unibyte temp buffer (`coding-system-for-read`/`-write` bound to `binary`). Exit 0 and output that sniffs as the same type → `:bytes` replaced, `:clean` t.
  - `heic` → argv `("heic:-" "-auto-orient" "-strip" "jpeg:-")`; on success `:image-type` `jpeg`, `:mime` `image/jpeg`, `:name` extension changed to `.jpg`, `:clean` t.
  - `gif` → unchanged, `:clean` t.
  - Not an image (`:image-type` nil) → unchanged, `:clean` t (nothing to clean).
  - Any failure (no program, non-zero exit, output not the expected type, error) → original ATT with `:clean` nil; logged without bytes.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-clean-attachment-jpeg-argv-and-result ()
  ;; stub executable-find -> "magick" for "magick"; stub call-process-region to record
  ;; PROGRAM and ARGS and replace the buffer with JPEG magic bytes, returning 0.
  ;; expect program "magick", args ("jpeg:-" "-auto-orient" "-strip" "jpeg:-"), :clean t
  ...)
(ert-deftest signel-clean-attachment-heic-becomes-jpeg ()
  ;; input name "IMG_1.HEIC", :image-type heic (construct the plist directly);
  ;; stub succeeds with JPEG bytes -> :name "IMG_1.jpg", :mime "image/jpeg", :image-type jpeg
  ...)
(ert-deftest signel-clean-attachment-no-imagemagick ()
  ;; executable-find -> nil for both; JPEG input -> same bytes, :clean nil
  ...)
(ert-deftest signel-clean-attachment-failure-keeps-original ()
  ;; call-process-region returns 1 -> original bytes, :clean nil
  ...)
(ert-deftest signel-clean-attachment-gif-and-files-untouched ()
  ;; gif and a pdf: call-process-region never called; :clean t
  ...)
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Strip photo metadata before sending`.

### Task 3: Pending row, paste and attach

**Files:**
- Modify: `signel.el` (`signel-chat-mode` and its keys; `signel--draw-prompt`; `signel-attach-file`; `;;; Outgoing Attachments`)
- Test: `test/signel-test.el`

**Interfaces:**
- Consumes: `signel--make-attachment`, `signel--read-file-bytes` (Task 1), `signel--clean-attachment` (Task 2), `signel--display-name` (existing).
- Produces: `defvar-local signel--pending nil`: list of attachment plists, oldest first.
- Produces: `(signel--add-pending ATT)`: cleans ATT with `signel--clean-attachment`, appends it, redraws the row.
- Produces: `(signel-remove-pending &optional ALL)`, interactive, `P` arg = ALL; bound to `C-c C-k`. Removes the last item, or all; `user-error` "No pending attachments" if empty.
- Produces: `(signel--draw-pending)`: keeps one overlay `signel--pending-overlay` (buffer-local) at the start of the prompt with a `before-string`: nothing when `signel--pending` is empty; otherwise `To NAME: ` followed by each item, then `"\n"`. NAME is the chat's display name (`signel--display-name` for a number/UUID chat; the group name from `signel--groups` or the ID for a group). Items: images whose `:image-type` is in `(png jpeg gif webp)` as a thumbnail (`create-image` from `:bytes`, explicit type, `:max-height 64`); others `[NAME]`; a `:clean` nil image gets ` ⚠ metadata not removed` after it. `signel--draw-prompt` calls `signel--draw-pending` after drawing, so the row survives incoming messages.
- Produces: `(signel--clipboard-image) -> (TYPE . BYTES) or nil`, never signals:
  1. If `gui-get-selection` is fboundp and a window system is active: try `(gui-get-selection 'CLIPBOARD 'image/png)`; a string whose bytes sniff as an image wins.
  2. `darwin`: `pngpaste -` via `call-process` into a unibyte buffer, if `executable-find`.
  3. Otherwise: `wl-paste --no-newline --type image/png` if `WAYLAND_DISPLAY` is set and the tool exists, else `xclip -selection clipboard -t image/png -o` if it exists.
  Each result is accepted only if exit 0 and the bytes sniff as an image.
- Produces: `(signel-paste)`, interactive, remapping `yank`, `evil-paste-after` and `evil-paste-before` in `signel-chat-mode` (via a `signel-chat-mode-map` with `[remap ...]` entries; keep the existing `RET`, `C-c C-c`, `C-c C-a` bindings in that map). If `evil-this-register` is bound and non-nil, or `signel--clipboard-image` returns nil, call the remapped original (`this-original-command`) with the same prefix argument via `call-interactively`. Otherwise add a pending attachment named `clipboard-YYYYMMDD-HHMMSS.EXT` (EXT from TYPE: png, jpg, gif, webp) and message "Image added; type a caption and press RET to send". History text is never modified, wherever point is.
- `signel-attach-file FILE` (same key, same prompt): reads the file with `signel--read-file-bytes`, keeps the base name, adds a pending attachment, messages as above. No longer sends.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-paste-text-falls-through ()
  ;; in a chat buffer, stub signel--clipboard-image -> nil; bind this-original-command to a stub
  ;; command that records it ran; call signel-paste via call-interactively -> stub ran, pending empty
  ...)
(ert-deftest signel-paste-image-queues-not-inserts ()
  ;; stub signel--clipboard-image -> (png . PNG-BYTES), stub signel--clean-attachment identity+:clean t;
  ;; point at point-min (history); call signel-paste -> one pending item named "clipboard-....png",
  ;; text before the prompt unchanged
  ...)
(ert-deftest signel-paste-respects-evil-register () ...)  ; evil-this-register ?a -> original runs even with an image
(ert-deftest signel-clipboard-image-tries-sources-in-order ()
  ;; window-system nil, system-type darwin; executable-find "pngpaste" -> path; call-process stub writes PNG bytes, returns 0
  ;; -> (png . BYTES); argv was ("-")
  ...)
(ert-deftest signel-clipboard-image-ignores-non-image ()  ; tool returns text bytes -> nil
  ...)
(ert-deftest signel-attach-file-queues ()
  ;; temp file with PNG bytes; signel-attach-file -> pending has one item with that base name; no send-rpc call
  ...)
(ert-deftest signel-remove-pending-last-and-all () ...)
(ert-deftest signel-pending-row-survives-incoming-message ()
  ;; add pending, then signel--insert-msg an incoming message -> overlay still at prompt start,
  ;; before-string contains "To "
  ...)
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Queue pasted and attached files above the prompt`.

### Task 4: Own images in the echo line

**Files:**
- Modify: `signel.el` (`signel--insert-attachment`)
- Test: `test/signel-test.el`

**Interfaces:**
- Consumes: attachment plists (Task 1).
- Produces: `signel--insert-attachment` accepts an alist `((signel-local . PLIST))` (used only for the owner's own sends). For it: images with `:image-type` in `(png jpeg gif webp)` are rendered from `:bytes` (`create-image` with explicit type, `:max-width 400`, animation bounded by `signel-animation-max-time` as elsewhere); anything else is inserted as plain text `[File: NAME]` (no button: there's no file to open).

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-own-image-renders-from-memory ()
  ;; stub create-image/insert-image to record; insert-msg with attachments
  ;; (list `((signel-local . ,png-att))) is-me t -> create-image called with :bytes, type png, data-p t
  ...)
(ert-deftest signel-own-file-is-plain-label () ...)  ; pdf att -> "[File: r.pdf]" text, no button at that position
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Show the owner's sent images in the chat`.

### Task 5: Sending caption plus attachments

**Files:**
- Modify: `signel.el` (`signel--send-input`, `signel--send-with-status`)
- Test: `test/signel-test.el`

**Interfaces:**
- Consumes: `signel--pending`, `signel--draw-pending` (Task 3); `signel--attachment-data-uri` (Task 1); local attachment rendering (Task 4).
- Produces: `(signel--send-with-status PARAMS TEXT &optional ATTACHMENTS ON-ERROR)`. ATTACHMENTS (list of plists) are passed to `signel--insert-msg` as `((signel-local . PLIST))` alists for the echo. ON-ERROR, if non-nil, is called with no arguments in the chat buffer after an RPC error (not on partial failure), after the status is set.
- `signel--send-input` behaviour:
  - Nothing to do (empty caption and no pending) → return, as today.
  - Process check before anything is removed (as today).
  - If any pending item is an image with `:clean` nil: `y-or-n-p` "Some images still contain metadata (e.g. location). Send anyway? ". On no, return with caption and pending untouched.
  - PARAMS: recipient/groupId as today; `message` only when the caption is non-empty; `attachments` vector of data URIs when pending is non-empty.
  - Echo TEXT is the caption (or nil when empty).
  - Pending is cleared and the row redrawn after the request is sent.
  - ON-ERROR restores: the sent attachments are appended to the current `signel--pending`; the caption is put back in the input only if the input is empty now.
- `signel-attach-file` no longer calls `signel--send-with-status` (Task 3).

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-send-attachments-without-caption ()
  ;; process stub present; pending = one PNG plist (:clean t); input empty; capture send params
  ;; -> params has attachments vector of 1 string starting "data:image/png;filename=", no message key;
  ;; pending empty afterwards
  ...)
(ert-deftest signel-send-caption-and-two-attachments () ...)   ; message "hi" and 2 data URIs, in order
(ert-deftest signel-send-unclean-declined-keeps-everything ()
  ;; pending has :clean nil image; y-or-n-p -> nil -> no send-rpc call; caption and pending intact
  ...)
(ert-deftest signel-send-error-restores-pending ()
  ;; deliver an RPC error to the callback -> pending restored, caption back in input
  ...)
(ert-deftest signel-send-log-hides-attachment-data ()
  ;; signel-log-message-bodies nil and t: summary of the captured request has no base64 payload
  ...)
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Send caption and queued attachments as one message`.

### Task 6: Documentation

**Files:**
- Modify: `signel.el` Commentary, `README.org` (Usage and keybinding table)

- [ ] **Step 1:** Document pasting images (`C-y`/`p`/`P`), `C-c C-a` queuing, `C-c C-k` / `C-u C-c C-k`, captions, metadata cleaning (needs ImageMagick; HEIC → JPEG), the optional clipboard tools per platform, and `signel-max-attachment-size`.
- [ ] **Step 2:** Run all tests + compile check, expect PASS.
- [ ] **Step 3: Commit** `Document sending images`.

### Task 7: Live check (owner present, controller runs it)

- [ ] **Step 1:** Reload the fork in the running Emacs: `(load "~/projects/signel/signel.el")`.
- [ ] **Step 2:** With the owner: take a screenshot to the clipboard, paste with `p` in a chat to a test contact, add a second image with `C-c C-a`, type a caption, `RET`. Check the recipient sees both images and the caption, the echo line shows them, and `*signel-log*` has no base64. Send a phone photo with location data and check (on the recipient side or by saving it and running `exiftool`/`mdls`) that GPS is gone. Paste text and check it pastes normally.
