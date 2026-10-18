;;; signel.el --- Signal client via signal-cli JSON-RPC  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Keenan Salandy

;; Author: Keenan Salandy <keenan@salandy.dev>
;; Maintainer: Keenan Salandy <keenan@salandy.dev>
;; URL: https://github.com/twillis209/signel
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;; This file is NOT a part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Signel.el provides a lightweight, text-based interface for Signal. It
;; communicates with a running `signal-cli' daemon via JSON-RPC.
;;
;; This is a fork of keenban/signel with security hardening:
;; https://github.com/twillis209/signel
;;
;; Features:
;; - Strict chat buffers (read-only history, guarded prompt).
;; - Inline images from known contacts; other images behind a button.
;; - Sticker support (APNG->GIF conversion for animation).
;; - Auto-refreshing dashboard of active chats.
;; - Native desktop notifications (osascript on macOS, D-Bus on Linux).
;; - Send images and files, with metadata stripped from images.
;;
;; Images: PNG, JPEG and GIF attachments and WebP stickers from known
;; contacts (a saved name, not blocked) show inline straight away.
;; Other images show a [Show image] or [Show sticker] button that
;; renders on click.  Formats are detected from the file contents, not
;; the sender's MIME type.  Animations stop after
;; `signel-animation-max-time' seconds.  See `signel-auto-display-images'.
;;
;; Received files: the button shows the file's real extension.  Opening
;; asks for confirmation; on macOS the file is marked with the
;; com.apple.quarantine attribute first.
;;
;; Names: contacts show under the owner's saved name; others show the
;; profile name and number.  Group chats always show numbers.  The
;; contact list is synced from the phone; use `signel-refresh-contacts'
;; to re-request it.  Messages wait up to `signel-contacts-timeout'
;; seconds for it.
;;
;; Sending shows "(sending…)" until signal-cli confirms; partial
;; group failures are listed.
;;
;; Sending images: in a chat, C-y (evil p/P, or Cmd-V) queues an image
;; from the clipboard instead of pasting text; text pastes as before.
;; C-c C-a queues any file.  Queued items appear above the prompt with
;; the recipient's name.  C-c C-k removes the last one, C-u C-c C-k all.
;; Type an optional caption and press RET to send everything as one
;; message.  Metadata (location, camera data) is stripped with
;; ImageMagick (`magick' or `convert'); HEIC is converted to JPEG; GIFs
;; and non-image files are sent unchanged.  If an image could not be
;; cleaned it is marked, and RET asks before sending.  If a send fails,
;; the items and caption come back.  The clipboard is read from Emacs,
;; then pngpaste (macOS), wl-paste (Wayland) or xclip (X11).  See
;; `signel-max-attachment-size'.
;;
;; Logging: message bodies are not logged unless
;; `signel-log-message-bodies' is non-nil.
;;
;; Other options: `signel-animation-max-time', `signel-auto-display-images',
;; `signel-contacts-timeout' and `signel-max-line-length' (which caps a
;; single line of signal-cli output).
;;
;; Prerequisites:
;; 1. signal-cli installed and in $PATH.
;; 2. A registered/linked Signal account.
;; 3. Optional: ImageMagick (`convert', or `magick') for animated stickers
;;    and for stripping metadata from sent images.
;; 4. Optional: pngpaste (macOS), wl-paste (Wayland) or xclip (X11) for
;;    pasting images from the clipboard.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'notifications nil t)
(require 'button)
(require 'image)
(require 'mailcap)
(require 'url-util)

;;; Configuration

(defgroup signel nil
  "Signal client for Emacs using signal-cli."
  :group 'comm
  :prefix "signel-")

(defcustom signel-account nil
  "The registered Signal phone number (e.g. +15550000000).
This must match the account registered with signal-cli."
  :type '(choice (const :tag "Not Set" nil) string))

(defcustom signel-cli-program (or (executable-find "signal-cli") "signal-cli")
  "Path to the signal-cli executable.
This program is a runtime dependency.  If it is in your variable `exec-path',
this is automatically set.  Otherwise, you must provide the absolute path."
  :type 'file)

(defcustom signel-data-directory (expand-file-name "~/.local/share/signal-cli")
  "Directory where signal-cli stores data (attachments, stickers, etc.).
Default on Linux is typically ~/.local/share/signal-cli."
  :type 'directory)

(defcustom signel-enable-animation t
  "If non-nil, animate stickers and GIFs in the chat buffer.
When nil, only the first frame of animated media will be displayed."
  :type 'boolean)

(defcustom signel-animation-max-time 15
  "Maximum number of seconds an animated image or sticker keeps animating."
  :type 'number)

(defcustom signel-auto-display-images t
  "If non-nil, show safe images from known contacts inline straight away.
Only PNG, JPEG and GIF attachments (and WebP stickers) sent by contacts
are decoded automatically.  Anything else, and every image when this is
nil, is shown as a button that displays the image when clicked."
  :type 'boolean)

(defcustom signel-prompt "> "
  "The prompt string displayed in chat buffers."
  :type 'string)

(defcustom signel-max-line-length 5000000
  "Maximum length of a single line of signal-cli output.
A longer line is dropped and logged; other lines are unaffected."
  :type 'integer)

(defcustom signel-log-message-bodies nil
  "If non-nil, log full JSON of requests and replies to *signel-log*.
By default only the method, id and (for sends) the recipient and
attachment count are logged, so message text, names and attachment
paths never reach the log.  `data:' URIs are always shortened."
  :type 'boolean)

(defcustom signel-contacts-timeout 5
  "Seconds to hold incoming messages while waiting for the contact list.
After this, queued messages are shown and everyone not yet known is
treated as a stranger."
  :type 'number)

(defcustom signel-auto-open-buffer t
  "If non-nil, automatically display the chat buffer when a message arrives."
  :type 'boolean)

(defcustom signel-max-attachment-size 104857600
  "Largest outgoing attachment, in bytes (default 100 MB)."
  :type 'integer)

;;; Faces

(defface signel-my-msg-face
  '((t :inherit font-lock-function-name-face))
  "Face applied to your own messages.")

(defface signel-other-msg-face
  '((t :inherit font-lock-variable-name-face))
  "Face applied to messages from other users.")

(defface signel-timestamp-face
  '((t :inherit shadow))
  "Face for message timestamps.")

(defface signel-error-face
  '((t :inherit error))
  "Face for error messages.")

;;; Internal State

(defconst signel--process-name "signal-rpc"
  "Internal name for the signal-cli process.")

(defconst signel--buffer-stderr " *signel-stderr*"
  "Name of the hidden buffer that receives process stderr.")

(defvar signel--rpc-id-counter 0
  "Counter for JSON-RPC request IDs.")

(defvar signel--request-buffer-map (make-hash-table :test 'equal)
  "Mapping of RPC ID to buffer name for error reporting.")

(defvar signel--rpc-callbacks (make-hash-table :test 'equal)
  "Mapping of RPC ID to a function called with (RESULT ERROR) on reply.")

(defvar signel--profile-names (make-hash-table :test 'equal)
  "Sanitised sender-chosen profile names, keyed by number and by UUID.
These are untrusted; see `signel--display-name'.")

(defvar signel--contacts (make-hash-table :test 'equal)
  "Address-book entries keyed by both number and UUID.
Each value is a plist (:name STRING :blocked BOOL).")

(defvar signel--groups (make-hash-table :test 'equal)
  "Sanitised names of groups we belong to, keyed by group ID.")

(defvar signel--contacts-pending nil
  "Non-nil while incoming messages are queued awaiting the contact list.")

(defvar signel--receive-queue nil
  "Queued `receive' params, newest first, awaiting the contact list.")

(defvar signel--contacts-timer nil
  "Timer that flushes `signel--receive-queue' if the contact list is slow.")

(defun signel--sanitize-name (string)
  "Return STRING without control or bidi characters, trimmed, or \"?\"."
  (let* ((clean (replace-regexp-in-string
                 "[[:cntrl:]\177\u0080-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]"
                 "" (if (stringp string) string "")))
         (trimmed (string-trim clean)))
    (if (string-empty-p trimmed) "?" trimmed)))

(declare-function notifications-notify "notifications" (&rest params))

(defun signel--notify-arg (string)
  "Return STRING made safe as an osascript argv item.
Sanitise, truncate to 200 characters, and prefix a space if it starts
with \"-\" so it cannot be parsed as an option."
  (let ((clean (signel--notify-truncate string)))
    (if (string-prefix-p "-" clean) (concat " " clean) clean)))

(defun signel--dbus-available-p ()
  "Return non-nil if D-Bus desktop notifications can be sent."
  (and (featurep 'dbusbind) (fboundp 'notifications-notify)))

(defun signel--notify-truncate (string)
  "Return STRING sanitised and truncated to 200 characters."
  (let ((clean (signel--sanitize-name string)))
    (if (> (length clean) 200) (substring clean 0 200) clean)))

(defun signel--notify-markup-escape (string)
  "Escape `&', `<' and `>' in STRING for a notification body."
  (replace-regexp-in-string
   ">" "&gt;"
   (replace-regexp-in-string
    "<" "&lt;"
    (replace-regexp-in-string "&" "&amp;" string t t)
    t t)
   t t))

(defun signel--notify (title body)
  "Show a desktop notification with TITLE and BODY.  Never signals.
On macOS run `osascript' asynchronously with TITLE and BODY as argv
items (never as script text).  Elsewhere use D-Bus when available."
  (condition-case err
      (cond
       ((eq system-type 'darwin)
        (if (not (executable-find "osascript"))
            (signel--log "Notification skipped: osascript not found")
          (make-process
           :name "signel-notify"
           :command (list "osascript"
                          "-e" "on run argv"
                          "-e" "display notification (item 2 of argv) with title (item 1 of argv)"
                          "-e" "end run"
                          (signel--notify-arg title)
                          (signel--notify-arg body))
           :connection-type 'pipe
           :noquery t
           :buffer nil
           :sentinel #'ignore)))
       ((signel--dbus-available-p)
        ;; Notification daemons interpret markup in the body.
        (notifications-notify
         :title (signel--notify-truncate title)
         :body (signel--notify-markup-escape (signel--notify-truncate body)))))
    (error (signel--log "Notification failed: %s" (error-message-string err))
           nil)))

(defun signel--mode-line-escape (string)
  "Escape `%' in STRING for use in the mode line."
  (replace-regexp-in-string "%" "%%" string t t))

(defun signel--display-name (number uuid profile-name group-p)
  "Return a trustworthy label for a sender.
Use the address-book name for NUMBER or UUID if there is one (plus
the number when GROUP-P).  Otherwise show the sanitised PROFILE-NAME
with NUMBER.  The first 8 characters of UUID stand in for a missing
number."
  (let* ((entry (or (and number (gethash number signel--contacts))
                    (and uuid (gethash uuid signel--contacts))))
         (name (plist-get entry :name))
         (id (cond (number number)
                   (uuid (substring uuid 0 (min 8 (length uuid))))
                   (t "?"))))
    (if (and (stringp name) (not (string-empty-p name)))
        (if group-p (format "%s (%s)" name id) name)
      (format "%s (%s)" (signel--sanitize-name profile-name) id))))

(defvar signel--active-chats (make-hash-table :test 'equal)
  "Set of currently active chat IDs.")

(defvar signel--partial-line ""
  "Buffer string for incomplete JSON lines received from the process.")

;;; Logging

(defun signel--log (fmt &rest args)
  "Log debug info to *signel-log* using FMT and ARGS."
  (with-current-buffer (get-buffer-create "*signel-log*")
    (goto-char (point-max))
    (insert (format-time-string "[%H:%M:%S] "))
    (insert (apply #'format fmt args))
    (insert "\n")))

(defun signel--shorten-data-uri-string (string)
  "Return STRING with each `data:' URI in it replaced by its length."
  (replace-regexp-in-string
   "data:[[:alnum:]+/=;,%._~!*-]+"
   (lambda (uri) (format "data:<%d bytes>" (length uri)))
   string t t))

(defun signel--shorten-data-uris (obj)
  "Return a copy of OBJ with each `data:' URI in its strings shortened.
See `signel--shorten-data-uri-string'."
  (cond
   ((stringp obj) (signel--shorten-data-uri-string obj))
   ((consp obj) (cons (signel--shorten-data-uris (car obj))
                      (signel--shorten-data-uris (cdr obj))))
   ((vectorp obj) (vconcat (mapcar #'signel--shorten-data-uris obj)))
   (t obj)))

(defun signel--log-summary (direction obj)
  "Return a log line for DIRECTION (a string) and the JSON object OBJ.
Unless `signel-log-message-bodies' is non-nil, only the method, id and,
for `send', the recipient or group and attachment count are included."
  (if signel-log-message-bodies
      (format "%s: %s" direction
              (json-encode (signel--shorten-data-uris obj)))
    (let* ((method (alist-get 'method obj))
           (id (alist-get 'id obj))
           (params (alist-get 'params obj))
           (parts (list (format "%s:" direction))))
      (when method (push (format "method=%s" method) parts))
      (when id (push (format "id=%s" id) parts))
      (when (equal method "send")
        (let ((target (or (alist-get 'recipient params)
                          (alist-get 'groupId params)
                          (alist-get 'username params)))
              (atts (alist-get 'attachments params)))
          (when target
            (push (format "to=%s"
                          (if (sequencep target)
                              (if (stringp target)
                                  target
                                (mapconcat #'identity target ","))
                            target))
                  parts))
          (push (format "attachments=%d" (length atts)) parts)))
      (mapconcat #'identity (nreverse parts) " "))))

(defun signel-toggle-log ()
  "Display the debug log buffer."
  (interactive)
  (display-buffer (get-buffer-create "*signel-log*")))

;;; Process Infrastructure

;;;###autoload
(defun signel-start ()
  "Start the signal-cli JSON-RPC process."
  (interactive)
  (unless (executable-find signel-cli-program)
    (user-error "The signal-cli executable '%s' was not found. Please install it or check `signel-cli-program'" signel-cli-program))

  (unless signel-account
    (user-error "Variable `signel-account' is not set"))

  (when (get-process signel--process-name)
    (delete-process signel--process-name))

  ;; State cleanup
  (setq signel--partial-line "")
  (clrhash signel--request-buffer-map)
  (clrhash signel--rpc-callbacks)
  (clrhash signel--contacts)
  (when (timerp signel--contacts-timer)
    (cancel-timer signel--contacts-timer))
  (setq signel--contacts-timer nil
        signel--contacts-pending nil
        signel--receive-queue nil)

  (let ((proc (make-process
               :name signel--process-name
               :buffer nil
               :connection-type 'pipe
               :noquery t
               :stderr (get-buffer-create signel--buffer-stderr)
               :command (list signel-cli-program "-a" signel-account "jsonRpc")
               :filter #'signel--process-filter
               :sentinel #'signel--process-sentinel
               :coding 'utf-8-unix)))
    (set-process-query-on-exit-flag proc nil)
    (signel--log "Signel service started.")
    (message "Signel service started.")
    ;; Queue incoming messages until the contact list is known.
    (setq signel--contacts-pending t
          signel--contacts-timer
          (run-at-time signel-contacts-timeout nil
                       #'signel--flush-receive-queue))
    (condition-case err
        (signel--request-contacts)
      (error (signel--log "listContacts failed: %s" err)
             (signel--flush-receive-queue)))))

(defun signel--request-contacts ()
  "Send `listContacts' and `listGroups'.
The contacts reply is loaded and then flushes the receive queue."
  (signel--send-rpc "listContacts" nil nil #'signel--contacts-reply)
  (condition-case err
      (signel--send-rpc "listGroups" nil nil
                        (lambda (result error-obj)
                          (if error-obj
                              (signel--log "listGroups failed: %s"
                                           (alist-get 'message error-obj))
                            (signel--load-groups result))))
    (error (signel--log "listGroups failed: %s" err))))

(defun signel-refresh-contacts ()
  "Re-request the contact and group lists from signal-cli."
  (interactive)
  (signel--request-contacts))

(defun signel--contacts-reply (result error-obj)
  "Handle the `listContacts' reply RESULT or ERROR-OBJ, then flush the queue."
  (unwind-protect
      (unless error-obj (signel--load-contacts result))
    (signel--flush-receive-queue)))

(defun signel--flush-receive-queue ()
  "Stop queueing incoming messages and handle those already queued, in order."
  (when (timerp signel--contacts-timer)
    (cancel-timer signel--contacts-timer))
  (setq signel--contacts-timer nil
        signel--contacts-pending nil)
  (let ((queued (nreverse signel--receive-queue)))
    (setq signel--receive-queue nil)
    (dolist (params queued)
      (condition-case err
          (signel--handle-receive params)
        (error (signel--log "Error handling queued message: %s" err))))))

(defun signel--load-contacts (result)
  "Rebuild `signel--contacts' from the `listContacts' RESULT.
Names are sanitised.  Entries with no usable name or nickName are skipped."
  (clrhash signel--contacts)
  (seq-doseq (c result)
    (let* ((number (alist-get 'number c))
           (uuid (alist-get 'uuid c))
           (name (seq-find (lambda (n) (not (equal n "?")))
                           (mapcar (lambda (k)
                                     (let ((v (alist-get k c)))
                                       (and (stringp v) (signel--sanitize-name v))))
                                   '(name nickName))))
           (entry (and name (list :name name
                                  :blocked (eq (alist-get 'isBlocked c) t)))))
      (when entry
        (when (stringp number) (puthash number entry signel--contacts))
        (when (stringp uuid) (puthash uuid entry signel--contacts))))))

(defun signel--load-groups (result)
  "Rebuild `signel--groups' from the `listGroups' RESULT.
Only named groups we are a member of and haven't blocked are kept."
  (clrhash signel--groups)
  (seq-doseq (g result)
    (let ((id (alist-get 'id g))
          (name (alist-get 'name g)))
      (when (and (stringp id) (stringp name)
                 (eq (alist-get 'isMember g) t)
                 (not (eq (alist-get 'isBlocked g) t)))
        (let ((clean (signel--sanitize-name name)))
          (unless (equal clean "?")
            (puthash id clean signel--groups)))))))

(defun signel--chat-candidates ()
  "Return an alist of (LABEL . CHAT-ID) for unblocked contacts and groups."
  (let ((ids (make-hash-table :test 'eq))
        candidates)
    ;; One contact is stored under both number and UUID; prefer the number.
    (maphash (lambda (key entry)
               (unless (or (plist-get entry :blocked)
                           (and (gethash entry ids)
                                (string-prefix-p "+" (gethash entry ids))))
                 (puthash entry key ids)))
             signel--contacts)
    (maphash (lambda (entry id)
               (push (cons (format "%s (%s)" (plist-get entry :name)
                                   (if (string-prefix-p "+" id)
                                       id
                                     (substring id 0 (min 8 (length id)))))
                           id)
                     candidates))
             ids)
    (maphash (lambda (id name)
               (push (cons (format "%s [group]" name) id) candidates))
             signel--groups)
    candidates))

(defun signel--resolve-recipient (input)
  "Return the chat ID for INPUT, a completion label or a raw number/ID."
  (or (cdr (assoc input (signel--chat-candidates)))
      (string-trim input)))

(defun signel--known-contact-p (number uuid)
  "Return non-nil if NUMBER or UUID is an unblocked, named contact, or is us."
  (or (and number signel-account (equal number signel-account))
      (let ((entry (or (and number (gethash number signel--contacts))
                       (and uuid (gethash uuid signel--contacts)))))
        (and entry
             (not (plist-get entry :blocked))
             (not (string-empty-p (or (plist-get entry :name) "")))))))

(defun signel-stop ()
  "Stop the Signel service."
  (interactive)
  (when (get-process signel--process-name)
    (delete-process signel--process-name)
    (message "Signel service stopped.")))

(defun signel--send-rpc (method params &optional target-buffer callback)
  "Send a JSON-RPC payload with METHOD and PARAMS; return the request ID.
If TARGET-BUFFER is non-nil, map the request ID to that buffer for
error handling.  If CALLBACK is non-nil, call it once as
\(funcall CALLBACK RESULT ERROR) when the reply arrives; one of
RESULT and ERROR is nil."
  (unless (get-process signel--process-name)
    (error "Signel service not running. M-x signel-start"))
  (let* ((id (cl-incf signel--rpc-id-counter))
         ;; Parameter-less methods omit `params' rather than send null.
         (req `((jsonrpc . "2.0")
                (method . ,method)
                ,@(and params `((params . ,params)))
                (id . ,id)))
         (json-str (json-encode req)))
    (when target-buffer
      (puthash id (buffer-name target-buffer) signel--request-buffer-map))
    (when callback
      (puthash id callback signel--rpc-callbacks))
    (signel--log "%s" (signel--log-summary "SEND" req))
    (process-send-string signel--process-name (concat json-str "\n"))
    id))

;;; Parsing & Dispatch

(defun signel--split-lines (pending string)
  "Append STRING to PENDING and split on newlines.
Return (LINES . REMAINDER), where LINES is a list of complete lines
without their newline and REMAINDER is the unterminated tail."
  (let* ((parts (split-string (concat pending string) "\n"))
         (remainder (car (last parts))))
    (cons (butlast parts) remainder)))

(defun signel--process-filter (_proc string)
  "Accumulate output from process and parse complete JSON objects from STRING.
Output is split into lines first; a line longer than
`signel-max-line-length' is dropped on its own and never affects others."
  (let* ((split (signel--split-lines signel--partial-line string))
         (lines (car split))
         (remainder (cdr split)))
    ;; DoS protection: discard an unterminated tail that is already too long.
    (if (> (length remainder) signel-max-line-length)
        (progn
          (setq signel--partial-line "")
          (signel--log "WARNING: Unterminated line exceeds %d chars. Dropped."
                       signel-max-line-length))
      (setq signel--partial-line remainder))

    (dolist (line lines)
      (if (> (length line) signel-max-line-length)
          (signel--log "WARNING: Line of %d chars exceeds limit. Dropped."
                       (length line))
        (setq line (string-trim line))
        (when (and (not (string-empty-p line)) (string-prefix-p "{" line))
          (condition-case err
              (let ((json (json-read-from-string line)))
                (signel--log "%s" (signel--log-summary "RECV" json))
                (signel--dispatch json))
            (error (signel--log "JSON Error: %s" err))))))))

(defun signel--process-sentinel (_proc event)
  "Log process EVENT for debugging."
  (signel--log "Process Event: %s" event)
  (when (string-prefix-p "exited" event)
    (message "Signel process exited.")))

(defun signel--dispatch (json)
  "Dispatch JSON object to appropriate handler."
  (let ((method (alist-get 'method json))
        (error-obj (alist-get 'error json))
        (id (alist-get 'id json))
        (params (alist-get 'params json)))
    (cond
     ((equal method "receive")
      (if signel--contacts-pending
          (push params signel--receive-queue)
        (signel--handle-receive params)))
     (error-obj
      ;; The callback must run even if reporting the error signals.
      (unwind-protect (signel--handle-error id error-obj)
        (signel--run-callback id nil error-obj)))
     ((and id (assq 'result json))
      (signel--run-callback id (alist-get 'result json) nil)))))

(defun signel--run-callback (id result error-obj)
  "Call and forget the callback registered for ID with RESULT and ERROR-OBJ."
  (let ((cb (gethash id signel--rpc-callbacks)))
    (when cb
      (remhash id signel--rpc-callbacks)
      (funcall cb result error-obj))))

(defun signel--handle-error (id error-obj)
  "Handle RPC errors for request ID using ERROR-OBJ."
  (let* ((buf-name (gethash id signel--request-buffer-map))
         (msg (signel--shorten-data-uri-string
               (format "%s" (alist-get 'message error-obj)))))
    (signel--log "RPC Error [%s]: %s" id msg)
    (when (and buf-name (get-buffer buf-name))
      (with-current-buffer buf-name
        (signel--insert-system-msg (format "ERROR: %s" msg) 'signel-error-face)))))

(defun signel--handle-receive (params)
  "Handle new messages, attachments, stickers, and sync events from PARAMS."
  (let* ((envelope (alist-get 'envelope params))
         (source (or (alist-get 'sourceNumber envelope) (alist-get 'source envelope)))
         (source-uuid (alist-get 'sourceUuid envelope))
         (source-number (or (alist-get 'sourceNumber envelope)
                            (and (stringp source) (string-prefix-p "+" source) source)))
         (source-name (let ((n (alist-get 'sourceName envelope)))
                        (when (stringp n)
                          (let ((clean (signel--sanitize-name n)))
                            (and (not (equal clean "?")) clean)))))
         (data (alist-get 'dataMessage envelope))
         (sync (alist-get 'syncMessage envelope))
         (typing (alist-get 'typingMessage envelope))
         (group-info (alist-get 'groupInfo data)))

    (when source-name
      (let ((clean (signel--sanitize-name source-name)))
        (when source-number (puthash source-number clean signel--profile-names))
        (when source-uuid (puthash source-uuid clean signel--profile-names))))

    (let* ((chat-id (if group-info (alist-get 'groupId group-info) source))
           (sender-label (signel--display-name
                          source-number source-uuid
                          (or source-name
                              (gethash source-number signel--profile-names)
                              (gethash source-uuid signel--profile-names))
                          (and group-info t))))
      (when chat-id
        (puthash chat-id t signel--active-chats)
        (signel--dashboard-refresh)

        ;; 1. Incoming Data (Text OR Attachments)
        (condition-case err
            (when data
              (let ((msg-text (alist-get 'message data))
                    (attachments (alist-get 'attachments data))
                    (sticker (alist-get 'sticker data))
                    (sender sender-label))

		(when (or msg-text attachments sticker)
                  (signel--insert-msg chat-id sender msg-text attachments sticker nil
                                      (signel--known-contact-p source-number source-uuid))

                  ;; Notify (never signals)
                  (condition-case nerr
                      (signel--notify
                       (format "Signel: %s" sender)
                       (cond (msg-text msg-text)
                             (sticker "[Sticker]")
                             (attachments "[Attachment]")
                             (t "New Message")))
                    (error (signel--log "Notify failed: %s"
                                        (error-message-string nerr))))

                  (when signel-auto-open-buffer
                    (display-buffer (signel--get-buffer chat-id))))))
          (error (signel--log "Error handling incoming data: %s" (error-message-string err))))

        ;; 2. Sync (My sent messages)
        (condition-case err
            (when sync
              (let* ((sent (alist-get 'sentMessage sync))
                     (dest (alist-get 'destinationNumber sent))
                     (msg-text (alist-get 'message sent))
                     (attachments (alist-get 'attachments sent))
                     (sticker (alist-get 'sticker sent)))
		(when (and dest (or msg-text attachments sticker))
                  (signel--insert-msg dest "Me" msg-text attachments sticker t t))))
          (error (signel--log "Error handling sync message: %s" (error-message-string err))))

        ;; 3. Typing
        (condition-case err
            (when typing
              (let ((action (alist-get 'action typing)))
		(when (member action '("STARTED" "STOPPED"))
                  (with-current-buffer (signel--get-buffer chat-id)
                    (setq mode-line-process
                          (and (string= action "STARTED")
                               (format " [%s...]" (signel--mode-line-escape sender-label))))
                    (force-mode-line-update)))))
          (error (signel--log "Error handling typing indicator: %s" (error-message-string err))))))))

;;; Media & Stickers

(defun signel--find-sticker (pack-id sticker-id)
  "Find the local sticker file for PACK-ID and STICKER-ID using manifest.json."
  (let* ((base-dir (expand-file-name "stickers/" signel-data-directory))
         (pack-dir (expand-file-name pack-id base-dir))
         (manifest-file (expand-file-name "manifest.json" pack-dir)))
    (if (file-exists-p manifest-file)
        ;; METHOD 1: Use manifest.json (Accurate)
        (condition-case nil
            (let* ((json-object-type 'alist)
                   (json-array-type 'list)
                   (manifest (json-read-file manifest-file))
                   (stickers (alist-get 'stickers manifest))
                   (sticker-info (seq-find (lambda (s) (= (alist-get 'id s) sticker-id)) stickers))
                   (file-name (alist-get 'file sticker-info)))
              (when file-name
                (expand-file-name file-name pack-dir)))
          (error nil))
      ;; METHOD 2: Fallback (Guessing)
      (let* ((path-no-ext (expand-file-name (number-to-string sticker-id) pack-dir))
             (path-webp (concat path-no-ext ".webp")))
        (cond
         ((file-exists-p path-webp) path-webp)
         ((file-exists-p path-no-ext) path-no-ext)
         (t nil))))))

(defun signel--convert-apng-to-gif (file)
  "Convert APNG FILE to a temporary GIF using ImageMagick `convert'.
Returns the path to the temporary GIF."
  (let ((tmp-gif (make-temp-file "signel-sticker-" nil ".gif")))
    (if (executable-find "convert")
        (with-temp-buffer
          ;; Run: convert apng:INPUT -coalesce gif:OUTPUT
          (if (eq 0 (call-process "convert" nil nil nil
                                  (concat "apng:" file)
                                  "-coalesce"
                                  tmp-gif))
              tmp-gif
            (signel--log "Failed to convert APNG to GIF. `convert' exit code non-zero.")
            ;; Cleanup failed file if it was created
            (when (file-exists-p tmp-gif) (delete-file tmp-gif))
            nil))
      (signel--log "ImageMagick `convert' not found. Cannot animate APNG.")
      (when (file-exists-p tmp-gif) (delete-file tmp-gif))
      nil)))

;; Image types are always taken from the file's own bytes, never from the
;; sender-supplied MIME type or file name.  Nothing is decoded for the
;; button case until the owner clicks.

(defun signel--sniff-image-buffer ()
  "Return the image type of the unibyte bytes in the current buffer, or nil.
Matches `image-type-header-regexps' directly, so the answer does not
depend on which image libraries this Emacs was built with."
  (let ((case-fold-search nil)
        (header nil))
    (save-excursion
      (goto-char (point-min))
      (cl-loop for (regexp . type) in image-type-header-regexps
               when (cond ((symbolp type) (and (looking-at-p regexp) type))
                          ((and (consp type) (looking-at-p regexp)
                                (funcall (car type)
                                         (or header
                                             (setq header
                                                   (buffer-substring
                                                    (point-min)
                                                    (min (point-max)
                                                         (+ (point-min) 8192)))))))
                           (cdr type)))
               return it))))

(defun signel--sniff-image-type (file)
  "Return the image type of FILE from its first bytes, or nil.
The MIME type and file name are ignored."
  (when (and (stringp file) (file-regular-p file) (file-readable-p file))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file nil 0 8192)
      (signel--sniff-image-buffer))))

(defun signel--image-action (sniffed-type known-p sticker-p)
  "Decide how to show media of SNIFFED-TYPE.
KNOWN-P is non-nil if the sender is a known contact; STICKER-P is non-nil
for stickers.  Return `inline', `button' or `file'.  PostScript is
always `file': rendering it would run Ghostscript."
  (cond ((memq sniffed-type '(nil postscript)) 'file)
        ((not signel-auto-display-images) 'button)
        ((and known-p (memq sniffed-type '(png jpeg gif))) 'inline)
        ((and known-p sticker-p (eq sniffed-type 'webp)) 'inline)
        (t 'button)))

(defun signel--read-image-file (file)
  "Return (TYPE . BYTES) for FILE, TYPE being sniffed from BYTES."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (cons (signel--sniff-image-buffer) (buffer-string))))

(defun signel--insert-image-data (data type max-width)
  "Insert the image DATA of TYPE at point, at most MAX-WIDTH pixels wide.
Animation stops after `signel-animation-max-time' seconds.
Return non-nil if an image was inserted."
  (let ((image (create-image data type t :max-width max-width)))
    (when image
      (insert-image image)
      (when (and signel-enable-animation (fboundp 'image-animate)
                 (image-multi-frame-p image))
        (image-animate image nil signel-animation-max-time))
      t)))

(defun signel--render-image (file expected-type max-width sticker-p)
  "Insert the image in FILE at point, at most MAX-WIDTH pixels wide.
The bytes are read once and decoded from memory with their sniffed type.
If EXPECTED-TYPE is non-nil and the bytes are of another type, nothing is
decoded.  For a sticker (STICKER-P non-nil), a PNG is converted to a GIF
so APNG stickers animate; the GIF is deleted as soon as it is read.
Animation stops after `signel-animation-max-time' seconds.
Return non-nil if an image was inserted."
  (let* ((loaded (signel--read-image-file file))
         (type (car loaded))
         (data (cdr loaded)))
    (when (and type (or (null expected-type) (eq type expected-type)))
      (when (and sticker-p (eq type 'png) (executable-find "convert"))
        (let ((gif (signel--convert-apng-to-gif file)))
          (when gif
            (unwind-protect
                (let ((converted (signel--read-image-file gif)))
                  (when (eq (car converted) 'gif)
                    (setq type 'gif
                          data (cdr converted))))
              (when (file-exists-p gif) (delete-file gif))))))
      (signel--insert-image-data data type max-width))))

(defun signel--show-image (button file max-width sticker-p)
  "Replace BUTTON with the image in FILE, as the owner asked.
MAX-WIDTH and STICKER-P are as for `signel--render-image'.  Any image type
the bytes sniff as is accepted, since the owner chose to see it."
  (with-current-buffer (if (markerp button) (marker-buffer button) (current-buffer))
    (let ((inhibit-read-only t)
          (start (button-start button))
          (end (button-end button)))
      (save-excursion
        (goto-char start)
        (delete-region start end)
        (unless (condition-case err
                    (signel--render-image file nil max-width sticker-p)
                  (error
                   (signel--log "Image render error: %s" (error-message-string err))
                   nil))
          (insert (propertize "[Couldn't display image]" 'face 'signel-error-face)))))))

(defun signel--insert-image-button (label file max-width sticker-p)
  "Insert a button LABEL that shows the image in FILE when clicked.
MAX-WIDTH and STICKER-P are passed to `signel--show-image'."
  (insert-button label
                 'action (lambda (button)
                           (signel--show-image button file max-width sticker-p))
                 'follow-link t
                 'face 'link
                 'help-echo "Not shown automatically.  Click to display."))

(defun signel--insert-sticker (sticker &optional known-p)
  "Insert STICKER (an alist from signal-cli) at point.
KNOWN-P is non-nil if the sender is a known contact."
  (let* ((pack-id (alist-get 'packId sticker))
         (sticker-id (alist-get 'stickerId sticker))
         (emoji (let ((e (alist-get 'emoji sticker)))
                  (if (and (stringp e) (not (string-empty-p e)))
                      (signel--sanitize-name e)
                    "🧩")))
         (file (if (and pack-id sticker-id)
                   (signel--find-sticker pack-id sticker-id)
                 nil))
         (type (and file (signel--sniff-image-type file))))
    (insert "\n")
    (pcase (if (and file (file-exists-p file))
               (signel--image-action type known-p t)
             'missing)
      ('inline
       (unless (signel--render-image file type 150 t)
         (insert (propertize (format "[Sticker %s (Render Failed)]" emoji)
                             'face 'font-lock-warning-face))))
      ('button
       (signel--insert-image-button (format "[Show sticker %s]" emoji) file 150 t))
      ;; File not found, or not an image
      (_
       (insert (propertize (format "[Sticker %s]" emoji)
                           'face 'font-lock-constant-face))))))

(defun signel--insert-image-file (file known-p)
  "Insert FILE as an inline image or a [Show image] button.
KNOWN-P is non-nil if the sender is a known contact.  Return nil, inserting
nothing, if FILE is not an image."
  (let ((type (signel--sniff-image-type file)))
    (pcase (signel--image-action type known-p nil)
      ('inline
       (unless (signel--render-image file type 400 nil)
         (insert (propertize "[Couldn't display image]" 'face 'signel-error-face)))
       t)
      ('button
       (signel--insert-image-button "[Show image]" file 400 nil)
       t)
      (_ nil))))

;;; Outgoing Attachments

;; Attachments are held in memory as plists and sent to signal-cli as
;; `data:' URIs, so nothing is written to disk.

(defun signel--check-attachment-size (size)
  "Signal a `user-error' if SIZE bytes exceeds `signel-max-attachment-size'."
  (when (> size signel-max-attachment-size)
    (user-error "Attachment is %d bytes, over the limit of %d (signel-max-attachment-size)"
                size signel-max-attachment-size)))

(defun signel--make-attachment (name bytes)
  "Return an attachment plist for NAME and the unibyte string BYTES.
Keys: :name :bytes :image-type :mime :clean.  The image type comes from
BYTES, never from NAME.  A multibyte BYTES holding only raw bytes is
converted to unibyte; one with other characters signals an error.
Signal a `user-error' if BYTES is too large."
  (setq bytes (string-to-unibyte bytes))
  (signel--check-attachment-size (length bytes))
  (let* ((clean-name (replace-regexp-in-string
                      "[/\\\\]" "_"
                      (signel--sanitize-name (file-name-nondirectory (or name "")))))
         (type (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert bytes)
                 (signel--sniff-image-buffer)))
         (ext (file-name-extension clean-name))
         (mime (or (cdr (assq type '((png . "image/png") (jpeg . "image/jpeg")
                                     (gif . "image/gif") (webp . "image/webp")
                                     (heic . "image/heic"))))
                   (and ext (mailcap-extension-to-mime ext))
                   "application/octet-stream")))
    (list :name clean-name :bytes bytes :image-type type :mime mime :clean nil)))

(defun signel--attachment-data-uri (att)
  "Return the signal-cli data URI for attachment plist ATT."
  (format "data:%s;filename=%s;base64,%s"
          (plist-get att :mime)
          (url-hexify-string (plist-get att :name))
          (base64-encode-string (plist-get att :bytes) t)))

(defun signel--read-file-bytes (file)
  "Return the contents of FILE as a unibyte string.
Signal a `user-error' before reading if it exceeds the size limit."
  (let ((size (file-attribute-size (file-attributes file))))
    (when size (signel--check-attachment-size size)))
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun signel--clipboard-command-bytes (program &rest args)
  "Run PROGRAM with ARGS and return its stdout as a unibyte string.
Return nil if PROGRAM is not installed or exits non-zero."
  (when (executable-find program)
    (let ((coding-system-for-read 'binary))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (when (eq 0 (apply #'call-process program nil (list t nil) nil args))
          (buffer-string))))))

(defun signel--clipboard-image ()
  "Return the clipboard image as (TYPE . BYTES), or nil.  Never signals.
Ask Emacs for an image/png selection when a window system is active,
then fall back to pngpaste (macOS), wl-paste (Wayland) or xclip.  The
bytes must sniff as a raster image type; text formats such as SVG or
PostScript are rejected, since on some systems a text selection is
returned whatever target is asked for."
  (condition-case err
      (let ((check (lambda (data)
                     ;; A multibyte text selection fails `string-to-unibyte';
                     ;; treat it as no image so the tools are still tried.
                     (ignore-errors
                       (when (stringp data)
                         (let* ((bytes (string-to-unibyte data))
                                (type (signel--sniff-bytes bytes)))
                           (and (memq type '(png jpeg gif webp tiff heic))
                                (cons type bytes))))))))
        (or (and (fboundp 'gui-get-selection) window-system
                 (funcall check (ignore-errors
                                  (gui-get-selection 'CLIPBOARD 'image/png))))
            (let ((argv (cond
                         ((eq system-type 'darwin) '("pngpaste" "-"))
                         ((and (getenv "WAYLAND_DISPLAY")
                               (executable-find "wl-paste"))
                          '("wl-paste" "--no-newline" "--type" "image/png"))
                         (t '("xclip" "-selection" "clipboard"
                              "-t" "image/png" "-o")))))
              (if (executable-find (car argv))
                  (funcall check
                           (apply #'signel--clipboard-command-bytes argv))
                (signel--log "No clipboard image tool found")
                nil))))
    (error (signel--log "Clipboard image read failed: %s" (error-message-string err))
           nil)))

;;; Metadata cleaning

(defun signel--imagemagick-program ()
  "Return the ImageMagick executable name (`magick' or `convert'), or nil."
  (cond ((executable-find "magick") "magick")
        ((executable-find "convert") "convert")))

(defun signel--run-imagemagick (bytes args)
  "Pipe the unibyte string BYTES through ImageMagick with argument list ARGS.
Return the output bytes on exit status 0, else nil."
  (let ((program (signel--imagemagick-program)))
    (when program
      (let ((coding-system-for-read 'binary)
            (coding-system-for-write 'binary))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert bytes)
          (when (eq 0 (apply #'call-process-region
                             (point-min) (point-max) program t (list t nil) nil args))
            (buffer-string)))))))

(defun signel--sniff-bytes (bytes)
  "Return the image type of the unibyte string BYTES, or nil."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert bytes)
    (signel--sniff-image-buffer)))

(defun signel--clean-attachment (att)
  "Return a new attachment plist: ATT with photo metadata stripped.
JPEG, PNG, WebP and TIFF are re-encoded through ImageMagick with
`-auto-orient -strip'; HEIC is converted to JPEG.  Other types carry no
EXIF container and are returned unchanged and clean.  On any failure
return ATT with :clean nil."
  (let* ((type (plist-get att :image-type))
         (att (copy-sequence att)))
    (if (not (memq type '(jpeg png webp tiff heic)))
        (plist-put att :clean t)
      (let* ((out-type (if (eq type 'heic) 'jpeg type))
             (args (list (format "%s:-" type) "-auto-orient" "-strip"
                         (format "%s:-" out-type)))
             (out (condition-case err
                      (signel--run-imagemagick (plist-get att :bytes) args)
                    (error (signel--log "Metadata cleaning failed: %s"
                                        (error-message-string err))
                           nil))))
        (cond
         ((and out (eq (signel--sniff-bytes out) out-type))
          (setq att (plist-put att :bytes out))
          (when (eq type 'heic)
            (setq att (plist-put att :image-type 'jpeg))
            (setq att (plist-put att :mime "image/jpeg"))
            (setq att (plist-put
                       att :name
                       (concat (file-name-sans-extension (plist-get att :name))
                               ".jpg"))))
          (plist-put att :clean t))
         (t (signel--log "Metadata cleaning failed for a %s attachment" type)
            (plist-put att :clean nil)))))))

;;; Received files

(defun signel--file-label (name path)
  "Return a button label for NAME, the sender's name for the file at PATH.
NAME is sanitised; the extension shown is that of the on-disk PATH."
  (let ((ext (file-name-extension path)))
    (format "[File: %s (%s)]" (signel--sanitize-name name)
            (if (and ext (not (string-empty-p ext)))
                (concat "." (signel--sanitize-name ext))
              "no extension"))))

(defun signel--open-attachment (path)
  "Open the received file PATH after asking for confirmation.
On macOS, mark it quarantined first so Gatekeeper checks it."
  (when (y-or-n-p (format "Open received file %s%s? "
                          (signel--sanitize-name (file-name-nondirectory path))
                          (let ((ext (file-name-extension path)))
                            (if (and ext (not (string-empty-p ext)))
                                (format " (.%s)" (signel--sanitize-name ext))
                              " (no extension)"))))
    (when (eq system-type 'darwin)
      (condition-case err
          (let ((status (call-process
                         "xattr" nil nil nil "-w" "com.apple.quarantine"
                         (format "0081;%x;signel;" (truncate (float-time)))
                         path)))
            (unless (eq status 0)
              (signel--log "xattr quarantine of %s failed: %s" path status)))
        (error (signel--log "xattr quarantine of %s failed: %s" path err))))
    (browse-url-of-file path)))

(defun signel--insert-file-button (name path type)
  "Insert a button that opens the on-disk file PATH, sent as NAME of TYPE."
  (insert-button (signel--file-label name path)
                 'action (lambda (_) (signel--open-attachment path))
                 'face 'link
                 'help-echo (format "Type: %s\nPath: %s"
                                    (signel--sanitize-name type)
                                    (signel--sanitize-name path))))

(defun signel--insert-attachment (att &optional known-p)
  "Insert a button or inline image for the attachment ATT at point.
KNOWN-P is non-nil if the sender is a known contact.
An ATT of the form ((signel-local . PLIST)) is one of the owner's own
sends, shown from memory: a sniffed image inline, anything else as a
plain label (there is no file to open)."
  (if (assq 'signel-local att)
      (signel--insert-local-attachment (alist-get 'signel-local att))
    (signel--insert-received-attachment att known-p)))

(defun signel--insert-local-attachment (plist)
  "Insert the owner's own attachment PLIST at point."
  (unless (and (memq (plist-get plist :image-type) '(png jpeg gif webp))
               (signel--insert-image-data (plist-get plist :bytes)
                                          (plist-get plist :image-type) 400))
    (insert (format "[File: %s]" (signel--sanitize-name (plist-get plist :name))))))

(defun signel--insert-received-attachment (att known-p)
  "Insert a button or inline image for the signal-cli attachment ATT.
KNOWN-P is as for `signel--insert-attachment'."
  (let* ((path (alist-get 'storedFilename att))
         (type (alist-get 'contentType att))
         (name (or (alist-get 'filename att) "attachment")))
    (cond
     ((and path (file-exists-p path))
      ;; A: Image (inline or button); B: File Button
      (unless (signel--insert-image-file path known-p)
        (signel--insert-file-button name path type)))
     ;; C: Missing/Not Downloaded
     (t
      (let* ((att-id (alist-get 'id att))
             (std-path (expand-file-name (format "attachments/%s" att-id) signel-data-directory))
             (exists (file-exists-p std-path)))
        (if exists
            (unless (signel--insert-image-file std-path known-p)
              (signel--insert-file-button name std-path type))
          (insert-button (format "[File: %s (Not Downloaded)]"
                                 (signel--sanitize-name name))
                         'action (lambda (_) (message "File not found at %s" std-path))
                         'face 'font-lock-comment-face)))))))

(defun signel--insert-media (attachments sticker &optional known-p)
  "Insert buttons or inline images for ATTACHMENTS and STICKER.
Handles animation support if enabled.  Each item is rendered on its own
so one malformed item shows a placeholder instead of aborting the rest.
KNOWN-P is non-nil if the sender is a known contact; see
`signel--image-action' for which images then render inline."
  (when sticker
    (condition-case err
        (signel--insert-sticker sticker known-p)
      (error
       (signel--log "Sticker render error: %s" (error-message-string err))
       (insert (propertize "[Couldn't display sticker]" 'face 'signel-error-face)))))
  (when attachments
    (dolist (att (if (vectorp attachments) (append attachments nil) attachments))
      (insert "\n")
      (condition-case err
          (signel--insert-attachment att known-p)
        (error
         (signel--log "Attachment render error: %s" (error-message-string err))
         (insert (propertize "[Couldn't display attachment]" 'face 'signel-error-face)))))))

;;; Buffer & UI Management

(defvar-local signel--chat-id nil
  "The Signal recipient ID associated with the current buffer.")

(defvar-local signel--input-marker nil
  "Marker indicating the start of the editable input area.")

(defun signel--guard-cursor ()
  "Ensure cursor stays in the editable prompt area."
  (let ((limit (if signel--input-marker (marker-position signel--input-marker) (point-min))))
    (when (< (point) limit)
      (goto-char limit))))

(defvar-local signel--pending nil
  "Attachment plists queued for the next message, oldest first.")

(defvar-local signel--pending-overlay nil
  "Overlay at the start of the prompt that shows `signel--pending'.")

(defvar signel-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'signel--send-input)
    (define-key map (kbd "C-c C-c") #'signel--send-input)
    (define-key map (kbd "C-c C-a") #'signel-attach-file)
    (define-key map (kbd "C-c C-k") #'signel-remove-pending)
    (define-key map [remap yank] #'signel-paste)
    (define-key map [remap evil-paste-after] #'signel-paste)
    (define-key map [remap evil-paste-before] #'signel-paste)
    map)
  "Keymap for `signel-chat-mode'.")

(define-derived-mode signel-chat-mode fundamental-mode "Signel"
  "Major mode for Signal chats."
  (setq-local paragraph-start (regexp-quote signel-prompt))
  ;; Every line is its own left-to-right bidi paragraph, so an
  ;; unterminated override in one message cannot reverse later lines.
  (setq-local bidi-paragraph-start-re "^")
  (setq-local bidi-paragraph-separate-re "^")
  (setq-local bidi-paragraph-direction 'left-to-right)
  (visual-line-mode 1)

  ;; Setup Input Marker
  (setq signel--input-marker (make-marker))

  (add-hook 'post-command-hook #'signel--guard-cursor nil t))

(defun signel--get-buffer (id)
  "Get or create a chat buffer for ID."
  (let* ((buf-name (format "*Signel: %s*" id))
         (buffer (get-buffer buf-name)))
    (unless buffer
      (setq buffer (get-buffer-create buf-name))
      (with-current-buffer buffer
        (signel-chat-mode)
        (setq signel--chat-id id)
        (signel--draw-prompt)))
    buffer))

(defun signel--draw-prompt ()
  "Draw the input prompt and update the input marker."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert (propertize signel-prompt
                        'read-only t
                        'face 'minibuffer-prompt
                        'rear-nonsticky '(read-only face)
                        'front-sticky '(read-only face)))
    ;; Update the marker to the end of the prompt
    (set-marker signel--input-marker (point))
    (signel--draw-pending)))

(defun signel--chat-name ()
  "Return the display name of the current chat."
  (let ((id signel--chat-id))
    (cond ((null id) "?")
          ((signel--is-group-id id) (or (gethash id signel--groups) id))
          (t (let ((number-p (string-prefix-p "+" id)))
               (signel--display-name (and number-p id) (and (not number-p) id)
                                     (gethash id signel--profile-names) nil))))))

(defun signel--pending-item-string (att)
  "Return the pending-row text for attachment ATT."
  (let* ((type (plist-get att :image-type))
         (label (format "[%s]" (plist-get att :name)))
         (image (and (memq type '(png jpeg gif webp))
                     (condition-case nil
                         (create-image (plist-get att :bytes) type t :max-height 64)
                       (error nil)))))
    (concat (if image (propertize label 'display image) label)
            (if (and type (not (plist-get att :clean)))
                (propertize " ⚠ metadata not removed" 'face 'signel-error-face)
              ""))))

(defun signel--draw-pending ()
  "Show `signel--pending' in an overlay just before the prompt."
  (when (and signel--input-marker (marker-position signel--input-marker))
    (let ((end (marker-position signel--input-marker)))
      (unless (overlayp signel--pending-overlay)
        (setq signel--pending-overlay (make-overlay end end nil t nil)))
      (move-overlay signel--pending-overlay
                    (max (point-min) (- end (length signel-prompt))) end)
      (overlay-put signel--pending-overlay 'before-string
                   (when signel--pending
                     (concat (format "To %s: " (signel--chat-name))
                             (mapconcat #'signel--pending-item-string
                                        signel--pending " ")
                             "\n"))))))

(defun signel--add-pending (att)
  "Clean the attachment ATT, queue it for the next message and redraw."
  (setq signel--pending
        (append signel--pending (list (signel--clean-attachment att))))
  (signel--draw-pending))

(defun signel-remove-pending (&optional all)
  "Remove the last queued attachment, or all of them with prefix ALL."
  (interactive "P")
  (unless signel--pending
    (user-error "No pending attachments"))
  (setq signel--pending (if all nil (butlast signel--pending)))
  (signel--draw-pending))

(defconst signel--image-extensions
  '((png . "png") (jpeg . "jpg") (gif . "gif") (webp . "webp"))
  "File name extensions for clipboard image types.")

(defconst signel--paste-commands '(yank evil-paste-after evil-paste-before)
  "Commands `signel-paste' remaps, and runs when there is no image.")

(defun signel-paste ()
  "Queue a clipboard image for this chat, or paste text as usual.
If the clipboard holds an image (and no evil register was named), add
it to the pending attachments without touching the buffer text.
Otherwise run the command this one remaps, with the same prefix arg."
  (interactive)
  (let ((image (and (not (bound-and-true-p evil-this-register))
                    (signel--clipboard-image))))
    (if (not image)
        (let ((cmd (if (memq this-original-command signel--paste-commands)
                       this-original-command
                     #'yank)))
          ;; So `last-command' is the paste, as `evil-paste-pop' requires.
          (setq this-command cmd)
          (call-interactively cmd))
      (signel--add-pending
       (signel--make-attachment
        (format "clipboard-%s.%s" (format-time-string "%Y%m%d-%H%M%S")
                (or (alist-get (car image) signel--image-extensions)
                    (symbol-name (car image))))
        (cdr image)))
      (message "Image added; type a caption and press RET to send"))))

(defmacro signel--with-prompt-preserved (&rest body)
  "Run BODY with the prompt and any typed input removed, then restore both.
BODY runs with point where the prompt line started.  The prompt is redrawn
and the owner's half-typed text re-inserted after it even if BODY signals;
point stays in the input area if it was there."
  (declare (indent 0) (debug t))
  `(let* ((inhibit-read-only t)
          (--sp-start (and signel--input-marker (marker-position signel--input-marker)))
          (--sp-typed (and --sp-start (buffer-substring --sp-start (point-max))))
          (--sp-in-input (and --sp-start (>= (point) --sp-start)))
          (--sp-offset (and --sp-in-input (- (point) --sp-start))))
     (unwind-protect
         (save-excursion
           (goto-char (or --sp-start (point-max)))
           (forward-line 0)
           (delete-region (point) (point-max))
           (unwind-protect (progn ,@body)
             (goto-char (point-max))
             (unless (bolp) (insert "\n"))
             (signel--draw-prompt)
             (when --sp-typed (insert --sp-typed))))
       (when --sp-in-input (goto-char (+ signel--input-marker --sp-offset))))))

(defun signel--insert-msg (id name text attachments sticker is-me &optional known-p)
  "Insert text and media into the buffer for chat ID.
NAME is the sender, TEXT is the content, ATTACHMENTS and STICKER contain
media data, and IS-ME is non-nil if the message is from the user.
KNOWN-P is passed to `signel--insert-media'.  Return a marker at the start
of the inserted message line."
  (with-current-buffer (signel--get-buffer id)
    (let ((name-face (if is-me 'signel-my-msg-face 'signel-other-msg-face))
          (line-start nil))
      (signel--with-prompt-preserved
       (setq line-start (copy-marker (point)))
       (insert (propertize (format-time-string "[%H:%M] ") 'face 'signel-timestamp-face))
       (insert (propertize (concat "<" name "> ") 'face name-face))
       (when text
         (condition-case err
             (insert text)
           (error
            (signel--log "Message render error: %s" (error-message-string err))
            (insert (propertize "[Couldn't display message]" 'face 'signel-error-face)))))
       (when (or attachments sticker)
         (when text (insert "\n"))
         (signel--insert-media attachments sticker known-p))
       (insert "\n"))
      (let ((win (get-buffer-window (current-buffer))))
        (when (and win (not (eq win (selected-window))))
          (set-window-point win (point-max))))
      line-start)))

(defun signel--insert-system-msg (text face)
  "Insert a system message with TEXT using FACE."
  (signel--with-prompt-preserved
   (insert (propertize (concat "*** " text "\n") 'face face))))

;;; Interactive Commands

(defun signel--is-group-id (id)
  "Return non-nil if ID look like a group ID (base64).
Returns nil if ID is a phone number (+) or UUID (contains -)."
  (not (or (string-prefix-p "+" id)
           (string-match-p "-" id))))

;;; Send status

(defun signel--send-failures (result)
  "Return one \"NUMBER-OR-UUID: TYPE\" string per failed entry in RESULT.
RESULT is a signal-cli \"send\" result; entries whose type is not
\"SUCCESS\" count as failures."
  (let (failures)
    (dolist (entry (append (alist-get 'results result) nil))
      (let ((type (alist-get 'type entry))
            (addr (alist-get 'recipientAddress entry)))
        (unless (equal type "SUCCESS")
          (push (format "%s: %s"
                        (or (alist-get 'number addr) (alist-get 'uuid addr) "?")
                        type)
                failures))))
    (nreverse failures)))

(defun signel--set-send-status (buffer marker status-id text face)
  "In BUFFER, replace the send status STATUS-ID found after MARKER.
Replace it with TEXT in FACE, or just remove it if TEXT is nil.  Do
nothing if BUFFER is dead or the status can't be found."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (signel--with-prompt-preserved
        (let ((beg (text-property-any (or marker (point-min)) (point-max)
                                      'signel-send-status status-id)))
          (when beg
            (let ((end (next-single-property-change
                        beg 'signel-send-status nil (point-max))))
              (delete-region beg end)
              (goto-char beg)
              (when text
                (insert (propertize text 'face face
                                    'signel-send-status status-id))))))))))

(defun signel--send-with-status (params text &optional attachments on-error)
  "Send PARAMS as a \"send\" request and echo TEXT as the owner's message.
ATTACHMENTS, a list of attachment plists, are shown in the echo from
memory.  The echo line ends with a status that is cleared on success and
replaced with the failure on partial delivery failure or an RPC error.
After an RPC error (not a partial failure), ON-ERROR, if non-nil, is
called with no arguments in the chat buffer, unless it has been killed."
  (let* ((buffer (current-buffer))
         (status-id (gensym "send"))
         (marker nil)
         (update (lambda (text face)
                   (signel--set-send-status buffer marker status-id text face))))
    ;; No target buffer: the failure is shown on the message line, not as a
    ;; separate system message.
    (signel--send-rpc
     "send" params nil
     (lambda (result err)
       (let ((failures (and (not err) (signel--send-failures result))))
         (cond
          (err (funcall update
                        (signel--shorten-data-uri-string
                         (format " (failed: %s)" (alist-get 'message err)))
                        'signel-error-face)
               (when (and on-error (buffer-live-p buffer))
                 (with-current-buffer buffer (funcall on-error))))
          (failures
           (funcall update (format " (not delivered to: %s)"
                                   (string-join failures ", "))
                    'signel-error-face))
          (t (funcall update nil nil))))))
    (setq marker (signel--insert-msg
                  signel--chat-id "Me" text
                  (mapcar (lambda (att) `((signel-local . ,att))) attachments)
                  nil t))
    (signel--with-prompt-preserved
      ;; The message's own newline is just before the prompt line.
      (goto-char (point-max))
      (when (eq (char-before) ?\n) (backward-char))
      (insert (propertize " (sending…)" 'face 'signel-timestamp-face
                          'signel-send-status status-id)))))

(defun signel--restore-unsent (attachments caption)
  "Put back ATTACHMENTS and CAPTION of a message that failed to send.
ATTACHMENTS are queued after any now pending.  CAPTION goes back in the
input only if the input is empty.  Point, and the point of any window
showing the buffer, follows the caption if it was in the empty input
and otherwise stays where it is."
  (when attachments
    (setq signel--pending (append signel--pending attachments))
    (signel--draw-pending))
  (when (and caption (= (marker-position signel--input-marker) (point-max)))
    (let ((at-end (= (point) (point-max)))
          (windows (seq-filter (lambda (w) (= (window-point w) (point-max)))
                               (get-buffer-window-list nil nil t))))
      (save-excursion
        (goto-char (point-max))
        (insert caption))
      (when at-end (goto-char (point-max)))
      (dolist (w windows) (set-window-point w (point-max))))))

(defun signel--input-caption ()
  "Return the trimmed input text, or nil if it is empty."
  (let ((text (string-trim (buffer-substring-no-properties
                            signel--input-marker (point-max)))))
    (and (not (string-empty-p text)) text)))

(defun signel--send-input ()
  "Send the input and any pending attachments to the current chat."
  (interactive)
  (let ((atts signel--pending))
    (when (or atts (signel--input-caption))
      ;; Check before deleting the draft, so it is not lost.
      (unless (get-process signel--process-name)
        (user-error "Signel service not running. M-x signel-start"))
      (when (or (not (cl-some (lambda (att) (and (plist-get att :image-type)
                                                 (not (plist-get att :clean))))
                              atts))
                (y-or-n-p "Some images still contain metadata (e.g. location). Send anyway? "))
        ;; Read the caption now: the input may have changed during `y-or-n-p'.
        (let ((caption (signel--input-caption))
              (params nil))
          (when atts
            (push `(attachments . ,(vconcat (mapcar #'signel--attachment-data-uri atts)))
                  params))
          (when caption
            (push `(message . ,caption) params))
          (if (signel--is-group-id signel--chat-id)
              (push `(groupId . ,signel--chat-id) params)
            (push `(recipient . [,signel--chat-id]) params))
          ;; Not START and END: a message may have arrived during `y-or-n-p'.
          (let ((inhibit-read-only t))
            (delete-region signel--input-marker (point-max)))
          ;; Unqueue only what is sent, and before sending: items may be
          ;; queued meanwhile, and a send error may re-queue these ones.
          (setq signel--pending
                (cl-remove-if (lambda (att) (memq att atts)) signel--pending))
          (signel--draw-pending)
          (signel--send-with-status
           params caption atts
           (lambda () (signel--restore-unsent atts caption))))))))

;;;###autoload
(defun signel-attach-file (file-path)
  "Queue FILE-PATH as an attachment for the next message in this chat."
  (interactive "fAttachment: ")
  (unless signel--chat-id
    (user-error "Not in a Signal chat buffer"))
  (let ((full-path (expand-file-name file-path)))
    (signel--add-pending
     (signel--make-attachment (file-name-nondirectory full-path)
                              (signel--read-file-bytes full-path)))
    (message "Image added; type a caption and press RET to send")))

;;;###autoload
(defun signel-chat (recipient)
  "Open a chat buffer for RECIPIENT (phone number, UUID or group ID).
Interactively, complete on contact and group names, or type a number."
  (interactive
   (let ((input (completing-read "Signal chat (name or +number): "
                                 (signel--chat-candidates))))
     (when (string-blank-p input)
       (user-error "No recipient given"))
     (list (signel--resolve-recipient input))))
  (let ((buffer (signel--get-buffer recipient)))
    (switch-to-buffer buffer)
    (message "Chat opened.")))

;;; Dashboard

(defvar signel-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'signel--dashboard-open-entry)
    (define-key map (kbd "n") #'forward-button)
    (define-key map (kbd "p") #'backward-button)
    (define-key map (kbd "g") #'signel--dashboard-refresh)
    map)
  "Keymap for `signel-dashboard-mode'.")

(define-derived-mode signel-dashboard-mode special-mode "Signel List"
  "Major mode for the list of active Signal chats.")

(defun signel--dashboard-draw ()
  "Redraw the dashboard content."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "Active Chats:\n")
    (insert "-------------\n")
    (maphash (lambda (id _)
               (let ((label (if (or (string-prefix-p "+" id)
                                    (string-match-p "\\`[0-9a-fA-F]\\{8\\}-" id))
                                (signel--display-name
                                 (and (string-prefix-p "+" id) id)
                                 (and (not (string-prefix-p "+" id)) id)
                                 (gethash id signel--profile-names) nil)
                              (format "%s (%s)" id id))))
                 (insert-button label
                                'action #'signel--dashboard-open-entry
                                'signel-id id
                                'follow-link t)
                 (insert "\n")))
             signel--active-chats)))

(defun signel--dashboard-refresh ()
  "Refresh the dashboard buffer."
  (interactive)
  (let ((buf (get-buffer "*Signel List*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((line (line-number-at-pos)))
          (signel--dashboard-draw)
          (goto-char (point-min))
          (forward-line (1- line)))))))

;;;###autoload
(defun signel-dashboard ()
  "Open the Signel Dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*Signel List*")))
    (with-current-buffer buf
      (signel-dashboard-mode)
      (signel--dashboard-draw))
    (switch-to-buffer buf)))

(defun signel--dashboard-open-entry (&optional btn)
  "Open chat for the button at point or BTN."
  (interactive)
  (let* ((button (or btn (button-at (point))))
         (id (and button (button-get button 'signel-id))))
    (if id
        (signel-chat id)
      (user-error "No chat entry at point"))))

(provide 'signel)
;;; signel.el ends here
