# Signel Security Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the security review findings F1–F10 in `signel.el` so that untrusted incoming data can't run code, break the chat buffer, or mislead the owner, while known contacts' images still show straight away.

**Architecture:** All changes stay in the single file `signel.el`. A new RPC callback table lets requests (`listContacts`, `send`) receive their `result`. A contact table built from `listContacts` drives one pure decision function for images, names and trust. Rendering of each message is isolated with `condition-case` / `unwind-protect`. Pure helpers are unit-tested with ERT in batch Emacs; anything that sends real Signal messages is checked by hand with the owner present (Task 11).

**Tech Stack:** Emacs Lisp (lexical binding, Emacs 27.1+), ERT, signal-cli 0.14.9 JSON-RPC over stdio.

**Spec:** `docs/superpowers/specs/2026-10-17-security-fixes-design.md`

## Global Constraints

- `Package-Requires: ((emacs "27.1"))` stays unless a task needs newer; if so, change the header and say why in the commit.
- Single-file package. No new hard dependencies. External tools (`xattr`, `osascript`, `convert`) are optional and run via `make-process`/`call-process` with argv lists. Never `shell-command`, `start-process-shell-command`, `osascript` script text containing message/name/ID data, or `eval`.
- Must work on macOS NS builds without D-Bus and on Linux with D-Bus.
- Must not break: sending text, receiving text, groups, attachments, stickers, dashboard, existing defcustoms (`signel-account`, `signel-cli-program`, `signel-data-directory`, `signel-enable-animation`, `signel-prompt`, `signel-auto-open-buffer`).
- No test or task may start `signal-cli` or send a Signal message, except Task 11 with the owner present.
- `signel.el` must byte-compile with no warnings.

**Commands used throughout** (run from the repo root, `~/projects/signel`):

```bash
EMACS=~/Applications/emacs.noindex/Emacs.app/Contents/MacOS/Emacs   # ~/opt/bin/emacs wrapper is broken
$EMACS -Q --batch -L . -l test/signel-test.el -f ert-run-tests-batch-and-exit            # all tests
$EMACS -Q --batch -L . -l test/signel-test.el --eval '(ert-run-tests-batch-and-exit "NAME")'  # one test
$EMACS -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile signel.el  # compile check
```

Expected for passing runs: `Ran N tests, N results as expected` and exit 0; compile check exits 0. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **The owner is half-way through typing when a message arrives.** The typed text must still be there, after the prompt, afterwards. (Test in Task 5.)
2. **`listContacts` never replies, or replies with an error.** Queued incoming messages must still be shown after the timeout, with everyone treated as unknown. (Test in Task 4.)
3. **An unknown sender posts an image in a group full of contacts.** It must get a `[Show image]` button; the group's membership doesn't make the sender trusted. (Test in Task 6.)
4. **A message or name starting with `-` (or containing `"`, `\`, newlines) goes to the macOS notifier.** It must be shown as text and never parsed as an option or script. (Test in Task 9.)
5. **Names with emoji or non-Latin letters.** Sanitising must strip only control and bidi characters, not ordinary Unicode. (Test in Task 3.)

---

### Task 1: Test harness and process plumbing (F10)

**Files:**
- Create: `test/signel-test.el`, `.gitignore` (contains `*.elc`)
- Modify: `signel.el:126-127` (state), `signel.el:147-172` (`signel-start`), `signel.el:201-222` (`signel--process-filter`)

**Interfaces:**
- Produces: `(signel--split-lines PENDING STRING) -> (LINES . REMAINDER)`: LINES is a list of complete lines (without `\n`), REMAINDER the unterminated tail.
- Produces: `defcustom signel-max-line-length` (integer, default `5000000`): a single line longer than this is dropped and logged; it never affects other lines.
- Produces: test file header with `(require 'ert) (require 'signel)` and a helper macro `signel-test-with-chat (ID &rest BODY)` that creates a fresh chat buffer via `signel--get-buffer`, runs BODY in it, and kills it afterwards. Later tasks add tests to this file.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-split-lines-basic ()
  (should (equal (signel--split-lines "" "{\"a\":1}\n{\"b\"")
                 '(("{\"a\":1}") . "{\"b\""))))
(ert-deftest signel-split-lines-joins-pending ()
  (should (equal (signel--split-lines "{\"b\"" ":2}\n")
                 '(("{\"b\":2}") . ""))))
(ert-deftest signel-filter-big-line-does-not-drop-others ()
  ;; with signel-max-line-length bound to 10, a 20-char line is dropped
  ;; but a following short complete line is still dispatched
  ...)  ; stub signel--dispatch with cl-letf and collect calls; expect exactly the short line's object
```

- [ ] **Step 2: Run tests, expect FAIL** (`signel--split-lines` void).
- [ ] **Step 3: Implement** `signel--split-lines`; rewrite `signel--process-filter` to split first, then drop over-long lines individually. If the unterminated remainder alone exceeds `signel-max-line-length`, discard it and log once. In `signel-start` add `:connection-type 'pipe` and `:stderr` (a buffer named by `signel--buffer-stderr`) and stop using that buffer as the process buffer.
- [ ] **Step 4: Run all tests and the compile check, expect PASS.**
- [ ] **Step 5: Commit** `Split process output before capping line length`.

### Task 2: Log redaction (F9) and RPC result callbacks (prerequisite for F1, F6)

**Files:**
- Modify: `signel.el:114-118` (state), `signel.el:131-137`, `signel.el:181-197` (`signel--send-rpc`), `signel.el:218`, `signel.el:230-247` (dispatch, error)
- Test: `test/signel-test.el`

**Interfaces:**
- Produces: `defcustom signel-log-message-bodies` (boolean, default nil).
- Produces: `(signel--log-summary DIRECTION OBJ) -> string`: with bodies off, contains only `jsonrpc` method, id, and for `send` the recipient/group plus attachment count; never message text, names, or attachment paths/data. With bodies on, the full JSON, except any string starting with `data:` is replaced by `data:<N bytes>`.
- Produces: `(signel--send-rpc METHOD PARAMS &optional TARGET-BUFFER CALLBACK) -> id`. CALLBACK is called as `(funcall CALLBACK RESULT ERROR)` exactly once when the matching reply arrives; one of RESULT/ERROR is nil. Existing callers keep working.
- Produces: `signel--dispatch` handles `result` replies (looks up and removes the callback by id). Errors still go to `signel--handle-error` and then to the callback if any.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-log-summary-hides-body ()
  (let ((signel-log-message-bodies nil))
    (should-not (string-match-p "secret"
      (signel--log-summary "SEND" '((method . "send") (id . 1)
                                    (params (message . "secret") (recipient . ["+44"]))))))))
(ert-deftest signel-log-summary-truncates-data-uri ()
  (let ((signel-log-message-bodies t))
    (should (string-match-p "data:<[0-9]+ bytes>"
      (signel--log-summary "SEND" `((params (attachments . [,(concat "data:image/png;base64," (make-string 5000 ?A))]))))))))
(ert-deftest signel-dispatch-calls-result-callback ()
  ;; stub process-send-string; send-rpc with a callback; dispatch ((id . ID) (result . ((ok . t))));
  ;; expect callback got RESULT ((ok . t)) and ERROR nil, and is not called on a second identical reply
  ...)
(ert-deftest signel-dispatch-calls-error-callback () ...)  ; same with (error (message . "boom")); ERROR non-nil
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Store callbacks in a new `signel--rpc-callbacks` hash (cleared in `signel-start`). Replace the two raw `signel--log "SEND/RECV: %s"` calls with `signel--log-summary`.
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Redact logs and route RPC results to callbacks`.

### Task 3: Sanitising and sender identity (F5)

**Files:**
- Modify: `signel.el:120-121`, `signel.el:249-301` (`signel--handle-receive`), `signel.el:596-609` (dashboard)
- Test: `test/signel-test.el`

**Interfaces:**
- Produces: `(signel--sanitize-name STRING) -> string`: removes C0/C1 control characters (including newline and tab) and bidi controls U+061C, U+200E, U+200F, U+202A–U+202E, U+2066–U+2069; trims; returns `"?"` for nil/empty results.
- Produces: `(signel--mode-line-escape STRING) -> string`: `%` → `%%`.
- Produces: `signel--contacts`: hash table (`equal`) mapping both number and UUID strings to a plist `(:name STRING :blocked BOOL)`. Filled by Task 4; this task only reads it.
- Produces: `(signel--display-name NUMBER UUID PROFILE-NAME GROUP-P) -> string`. If a contact entry with a non-empty `:name` exists for NUMBER or UUID: that name, plus ` (NUMBER)` when GROUP-P. Otherwise: sanitised PROFILE-NAME (or `"?"`) plus ` (NUMBER)`, or ` (UUID's first 8 chars)` when there is no number.
- Typing indicator: `mode-line-process` set via `signel--mode-line-escape`, cleared on `STOPPED`.
- Dashboard uses `signel--display-name` for one-to-one chats instead of `signel--contact-map` (which goes away).

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-sanitize-strips-controls-and-bidi ()
  (should (equal (signel--sanitize-name "Ali\ne‮fdp.exe") "Aliefdp.exe")))
(ert-deftest signel-sanitize-keeps-unicode ()
  (should (equal (signel--sanitize-name "Zoë 🚣 Ἀθηνᾶ") "Zoë 🚣 Ἀθηνᾶ")))
(ert-deftest signel-display-name-contact-wins ()
  (let ((signel--contacts (make-hash-table :test 'equal)))
    (puthash "+441" '(:name "Mum" :blocked nil) signel--contacts)
    (should (equal (signel--display-name "+441" nil "Totally Mum" nil) "Mum"))
    (should (equal (signel--display-name "+441" nil "Totally Mum" t) "Mum (+441)"))))
(ert-deftest signel-display-name-stranger-shows-number ()
  (let ((signel--contacts (make-hash-table :test 'equal)))
    (should (equal (signel--display-name "+449" nil "Mum" nil) "Mum (+449)"))
    (should (equal (signel--display-name nil "abcdef12-3456" "Mum" nil) "Mum (abcdef12)"))))
(ert-deftest signel-mode-line-escape ()
  (should (equal (signel--mode-line-escape "100%-") "100%%-")))
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** In `signel--handle-receive` read `sourceUuid` as well as `sourceNumber`, and use `signel--display-name` for the sender label.
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Show trusted names and numbers; sanitise sender names`.

### Task 4: Contact list and start-up queue (supports F1, F5)

**Files:**
- Modify: `signel.el` (state; `signel-start`; `signel--dispatch` receive branch)
- Test: `test/signel-test.el`

**Interfaces:**
- Consumes: `signel--send-rpc` with CALLBACK (Task 2); `signel--contacts` (Task 3).
- Produces: `(signel--load-contacts RESULT)`: RESULT is the `listContacts` result (vector of alists with keys `number`, `uuid`, `name`, `nickName`, `isBlocked`, per signal-cli 0.14.9 `JsonContact`). Rebuilds `signel--contacts`; `:name` is `name`, else `nickName`, sanitised; entries with neither are skipped.
- Produces: `(signel--known-contact-p NUMBER UUID) -> bool`: true iff an entry exists for NUMBER or UUID with non-empty `:name` and `:blocked` nil, or NUMBER equals `signel-account` (the owner's own messages, e.g. sync messages).
- Produces: `defcustom signel-contacts-timeout` (seconds, default 5). After `signel-start` sends `listContacts`, `receive` notifications are queued in order; the queue is flushed when the reply (or an error) arrives, or when the timeout fires, whichever is first. After that, receives are handled immediately.
- Produces: `(signel-refresh-contacts)` interactive command re-requesting `listContacts`. Refresh policy beyond start-up and this command is not needed.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-load-contacts-rules ()
  (signel--load-contacts
   (vector '((number . "+441") (uuid . "u1") (name . "Mum") (isBlocked . :json-false))
           '((number . "+442") (uuid . "u2") (name . "Ex") (isBlocked . t))
           '((number . "+443") (uuid . "u3") (name . nil) (nickName . nil))
           '((number . nil) (uuid . "u4") (name . "") (nickName . "Bob") (isBlocked . :json-false))))
  (should (signel--known-contact-p "+441" nil))
  (should (signel--known-contact-p nil "u1"))
  (should-not (signel--known-contact-p "+442" nil))   ; blocked
  (should-not (signel--known-contact-p "+443" nil))   ; no saved name
  (should (signel--known-contact-p nil "u4"))         ; nickname, UUID-only
  (let ((signel-account "+440")) (should (signel--known-contact-p "+440" nil))))
(ert-deftest signel-receives-queued-until-contacts ()
  ;; stub signel--handle-receive to record calls; put signel in "waiting" state;
  ;; dispatch two receives -> no calls; deliver listContacts result -> both handled, in order
  ...)
(ert-deftest signel-queue-flushes-on-contacts-error () ...)   ; error reply -> queue handled, nobody known
(ert-deftest signel-queue-flushes-on-timeout () ...)          ; call the timeout function directly -> queue handled
```

Note: `json-read-from-string` gives `:json-false` for `false`; treat only `t` as blocked.

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Use `run-at-time` for the timeout; cancel it when the reply arrives.
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Load contacts at start-up and queue early messages`.

### Task 5: Rendering robustness (F3)

**Files:**
- Modify: `signel.el:486-527` (`signel--insert-msg`, `signel--insert-system-msg`), `signel.el:249-301`
- Test: `test/signel-test.el`

**Interfaces:**
- Produces: `signel--insert-msg` keeps its signature `(ID NAME TEXT ATTACHMENTS STICKER IS-ME)` plus a new optional seventh argument `KNOWN-P` (used by Task 6) and returns a marker at the start of the inserted message line (used by Task 8).
- Behaviour: message text and each attachment/sticker are rendered inside their own `condition-case`; on error insert `[Couldn't display attachment]` (or `... sticker` / `... message`) in `signel-error-face` and log the error. The prompt is redrawn in `unwind-protect`, and any text the owner had typed after the prompt is preserved and re-inserted after the new prompt, with point kept in the input area if it was there.
- `signel--handle-receive`: the data, sync and typing branches each run inside their own `condition-case`, so a failure in one doesn't stop the others.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-insert-msg-survives-bad-attachment ()
  (signel-test-with-chat "+441"
    (signel--insert-msg "+441" "X" "hi" (vector '((id . "a") (contentType . nil))) nil nil)
    (should (string-match-p "Couldn't display" (buffer-string)))
    (should (string-suffix-p signel-prompt
              (buffer-substring-no-properties (point-min) signel--input-marker)))))
(ert-deftest signel-insert-msg-keeps-typed-input ()
  (signel-test-with-chat "+441"
    (goto-char (point-max)) (insert "half typed")
    (signel--insert-msg "+441" "X" "incoming" nil nil nil)
    (should (equal (buffer-substring-no-properties signel--input-marker (point-max)) "half typed"))))
(ert-deftest signel-insert-msg-error-in-media-keeps-prompt ()
  ;; cl-letf signel--insert-media to (error "boom"); prompt still last, text "hi" present
  ...)
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Isolate message rendering errors and keep the prompt`.

### Task 6: Image policy, stickers and animation (F1, F7, F8)

**Files:**
- Modify: `signel.el:75-78` (options), `signel.el:305-433` (sticker lookup, APNG conversion, `signel--insert-media`), `signel.el:249-301` (pass KNOWN-P)
- Test: `test/signel-test.el`

**Interfaces:**
- Consumes: `signel--known-contact-p` (Task 4); `signel--insert-msg` KNOWN-P argument (Task 5).
- Produces: `(signel--sniff-image-type FILE) -> symbol or nil`, from the file's first bytes matched against `image-type-header-regexps`; never the MIME type. (`image-type-from-file-header` also filters on `image-type-available-p`, which can differ in batch; match the regexps directly so the result doesn't depend on the build.)
- Produces: `(signel--image-action SNIFFED-TYPE KNOWN-P STICKER-P) -> 'inline | 'button | 'file`:
  - nil type → `'file`
  - `signel-auto-display-images` nil → `'button`
  - KNOWN-P and type in `(png jpeg gif)` → `'inline`
  - KNOWN-P, STICKER-P and type `webp` → `'inline`
  - any other image type → `'button`
- Produces: `defcustom signel-auto-display-images` (boolean, default t) and `defcustom signel-animation-max-time` (seconds, default 15), passed as LIMIT to `image-animate` (never `t`).
- `'button` inserts `[Show image]` (stickers: `[Show sticker EMOJI]`); clicking replaces the button with the rendered image (same rendering path as `'inline`). APNG→GIF conversion happens only when an image is actually rendered. The 5-second delete of the converted GIF is replaced by deleting it once `create-image` has the data (load with `:data` from the file contents, then delete).
- KNOWN-P for incoming data messages is `(signel--known-contact-p source-number source-uuid)` for the individual sender, also in groups. Sync messages (own sends) pass t.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-image-action-table ()
  (let ((signel-auto-display-images t))
    (should (eq (signel--image-action 'png t nil) 'inline))
    (should (eq (signel--image-action 'svg t nil) 'button))
    (should (eq (signel--image-action 'webp t nil) 'button))   ; WebP attachment from contact
    (should (eq (signel--image-action 'webp t t) 'inline))      ; WebP sticker from contact
    (should (eq (signel--image-action 'png nil nil) 'button))   ; stranger
    (should (eq (signel--image-action 'webp nil t) 'button))
    (should (eq (signel--image-action nil t nil) 'file)))
  (let ((signel-auto-display-images nil))
    (should (eq (signel--image-action 'png t nil) 'button))))
(ert-deftest signel-sniff-ignores-mime ()
  ;; write an SVG file named x.png; sniff returns svg
  ...)
(ert-deftest signel-group-stranger-gets-button ()
  ;; contacts: +441 known. receive a group dataMessage from +449 with a PNG attachment (fixture file);
  ;; stub create-image/insert-image to record calls -> no image created; buffer contains "[Show image]"
  ...)
(ert-deftest signel-animation-is-bounded ()
  ;; stub image-animate and image-multi-frame-p (-> t); render a GIF inline; LIMIT arg equals signel-animation-max-time
  ...)
```

Fixture images: write minimal headers with `(let ((coding-system-for-write 'no-conversion)) (write-region ...))` into `make-temp-file`; PNG `"\x89PNG\r\n\x1a\n"`, GIF `"GIF89a"`, JPEG `"\xff\xd8\xff"`, WebP `"RIFF\0\0\0\0WEBPVP8 "`, SVG `"<svg xmlns=\"http://www.w3.org/2000/svg\"/>"`. Batch Emacs can sniff these but can't decode them, so tests that reach rendering stub `create-image`, `insert-image`, `image-animate` and `image-multi-frame-p`.

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Only auto-display safe image formats from contacts`.

### Task 7: Received files (F2)

**Files:**
- Modify: `signel.el` (`signel--insert-media` file branches, formerly 411-433)
- Test: `test/signel-test.el`

**Interfaces:**
- Consumes: `signel--sanitize-name` (Task 3).
- Produces: `(signel--file-label NAME PATH) -> string`: `[File: SANITISED-NAME (.EXT)]` where EXT is `file-name-extension` of the on-disk PATH (`(no extension)` if none).
- Produces: `(signel--open-attachment PATH)`: asks `y-or-n-p` with the sanitised basename and real extension; on yes, on `darwin` runs `xattr -w com.apple.quarantine "0081;HEX-UNIX-TIME;signel;" PATH` via `call-process` (ignore failure, but log it), then `browse-url-of-file`. On no, does nothing.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-file-label-shows-real-extension ()
  (should (equal (signel--file-label "invoice‮fdp.terminal" "/x/abc.terminal")
                 "[File: invoicefdp.terminal (.terminal)]")))
(ert-deftest signel-open-attachment-declined-opens-nothing ()
  ;; stub y-or-n-p -> nil, browse-url-of-file and call-process record calls; expect none
  ...)
(ert-deftest signel-open-attachment-quarantines-on-mac ()
  ;; bind system-type 'darwin, y-or-n-p -> t; expect call-process "xattr" with argv
  ;; ("-w" "com.apple.quarantine" <string starting "0081;"> PATH) before browse-url-of-file
  ...)
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Confirm and quarantine before opening received files`.

### Task 8: Send status (F6)

**Files:**
- Modify: `signel.el:537-571` (`signel--send-input`, `signel-attach-file`)
- Test: `test/signel-test.el`

**Interfaces:**
- Consumes: `signel--send-rpc` CALLBACK (Task 2); marker returned by `signel--insert-msg` (Task 5).
- Produces: `(signel--send-failures RESULT) -> list of strings`: one `"NUMBER-OR-UUID: TYPE"` per entry in RESULT's `results` whose `type` isn't `"SUCCESS"` (shape per signal-cli 0.14.9: `{timestamp, results: [{recipientAddress: {uuid, number}, type}]}`).
- Behaviour: the local echo line ends with ` (sending…)` in `signel-timestamp-face`. On a result with no failures the status text is removed. On failures it becomes ` (not delivered to: A, B)` in `signel-error-face`. On an RPC error it becomes ` (failed: MESSAGE)`. The status text is found via a text property, not by position, so later messages don't break it.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-send-failures-parses-results ()
  (should (equal (signel--send-failures
                  '((timestamp . 1)
                    (results . [((recipientAddress (uuid . "u1") (number . "+441")) (type . "SUCCESS"))
                                ((recipientAddress (uuid . "u2") (number . nil)) (type . "UNREGISTERED_FAILURE"))])))
                 '("u2: UNREGISTERED_FAILURE"))))
(ert-deftest signel-send-shows-pending-then-clears () ...)        ; stub process-send-string; send; buffer has "(sending…)"; deliver success result -> gone
(ert-deftest signel-send-shows-partial-failure () ...)            ; deliver a result with one failure -> "not delivered to: u2"
(ert-deftest signel-send-status-survives-later-message () ...)    ; insert an incoming message between send and result; status still updated on the right line
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Show sending status and partial delivery failures`.

### Task 9: Notifications (F4)

**Files:**
- Modify: `signel.el:48` (make `notifications` a soft require), `signel.el:277-286`
- Test: `test/signel-test.el`

**Interfaces:**
- Consumes: `signel--sanitize-name` (Task 3).
- Produces: `(signel--notify TITLE BODY)`: never signals. On `darwin`, runs `osascript` asynchronously via `make-process` with argv
  `("osascript" "-e" "on run argv" "-e" "display notification (item 2 of argv) with title (item 1 of argv)" "-e" "end run" TITLE BODY)`,
  where TITLE and BODY are sanitised, truncated to 200 characters, and prefixed with a space if they start with `-`. Elsewhere, `notifications-notify` if `(featurep 'dbusbind)`; otherwise nothing. Any error is caught and logged.
- Auto-opening the chat buffer runs regardless of whether notifying worked.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest signel-notify-mac-uses-argv ()
  ;; system-type 'darwin; stub make-process to capture :command
  (let (cmd)
    (cl-letf (((symbol-function 'make-process) (lambda (&rest a) (setq cmd (plist-get a :command)) nil)))
      (let ((system-type 'darwin)) (signel--notify "Signel: X" "-e do shell script \"rm\"\nhi")))
    (should (equal (seq-take cmd 7) '("osascript" "-e" "on run argv" "-e"
                                      "display notification (item 2 of argv) with title (item 1 of argv)"
                                      "-e" "end run")))
    (should-not (string-prefix-p "-" (nth 8 cmd)))
    (should-not (string-match-p "\n" (nth 8 cmd)))))
(ert-deftest signel-notify-never-signals ()
  ;; make-process stub signals an error -> signel--notify returns normally
  ...)
(ert-deftest signel-auto-open-despite-notify-failure () ...)  ; stub signel--notify to error; receive a message; display-buffer called
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run all tests + compile check, expect PASS.**
- [ ] **Step 5: Commit** `Native macOS notifications without D-Bus`.

### Task 10: Documentation

**Files:**
- Modify: `signel.el:26-43` (Commentary), `README.org`

- [ ] **Step 1:** Update Commentary and README: the new options (`signel-auto-display-images`, `signel-animation-max-time`, `signel-log-message-bodies`, `signel-max-line-length`, `signel-contacts-timeout`), the image rules (contacts vs others, formats), `signel-refresh-contacts`, and that this is a fork (URL `https://github.com/twillis209/signel`, `URL:` header updated).
- [ ] **Step 2:** Run all tests + compile check, expect PASS.
- [ ] **Step 3: Commit** `Document security behaviour and new options`.

### Task 11: Wire into Spacemacs and live check (owner present)

**Files:**
- Modify: `~/.dotfiles/.spacemacs` (separate repo; do not commit there unless the owner asks)

- [ ] **Step 1:** Replace the `signel` entry in `dotspacemacs-additional-packages` with
  `(signel :location (recipe :fetcher local :repo "~/projects/signel" :files ("signel.el")))`, matching the existing `snakemake-mode` entry. In the running daemon, load the fork with `(load "~/projects/signel/signel.el")` rather than restarting.
- [ ] **Step 2:** With the owner, `M-x signel-start` and check, ticking each:
  - contacts load (`*signel-log*` shows the `listContacts` reply summary, no message text);
  - a text message from a contact arrives, shows the saved name, a macOS notification appears, the buffer opens;
  - a photo from a contact shows inline; a sticker from a contact shows inline and stops animating;
  - sending text shows `(sending…)` then clears;
  - a file attachment shows the real extension and asks before opening.
- [ ] **Step 3:** Push the branch to the fork (`git push -u origin security-fixes`) only after the owner says so.
