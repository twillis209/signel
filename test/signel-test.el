;;; signel-test.el --- ERT tests for signel  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:
;;   emacs -Q --batch -L . -l test/signel-test.el -f ert-run-tests-batch-and-exit
;; No test may start signal-cli or a real process; stub process functions
;; with `cl-letf'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'signel)

(defmacro signel-test-with-chat (id &rest body)
  "Run BODY in a fresh chat buffer for ID, then kill the buffer.
Any pre-existing buffer for ID is killed first so each test starts clean."
  (declare (indent 1) (debug t))
  `(let ((--signel-id-- ,id))
     (let ((--old-- (get-buffer (format "*Signel: %s*" --signel-id--))))
       (when --old-- (kill-buffer --old--)))
     (let ((--buf-- (signel--get-buffer --signel-id--)))
       (unwind-protect
           (with-current-buffer --buf-- ,@body)
         (when (buffer-live-p --buf--)
           (let ((kill-buffer-query-functions nil))
             (kill-buffer --buf--)))))))

(ert-deftest signel-test-with-chat-creates-and-kills ()
  (let (buf)
    (signel-test-with-chat "+15550001"
      (setq buf (current-buffer))
      (should (eq major-mode 'signel-chat-mode))
      (should (equal signel--chat-id "+15550001")))
    (should-not (buffer-live-p buf))))

(ert-deftest signel-split-lines-basic ()
  (should (equal (signel--split-lines "" "{\"a\":1}\n{\"b\"")
                 '(("{\"a\":1}") . "{\"b\""))))

(ert-deftest signel-split-lines-joins-pending ()
  (should (equal (signel--split-lines "{\"b\"" ":2}\n")
                 '(("{\"b\":2}") . ""))))

(ert-deftest signel-filter-big-line-does-not-drop-others ()
  (let ((signel--partial-line "")
        (signel-max-line-length 10)
        (calls nil))
    (cl-letf (((symbol-function 'signel--dispatch)
               (lambda (json) (push json calls))))
      (signel--process-filter
       nil (concat "{\"aaaaaaaaaaaaaaaaaaaa\":1}\n" "{\"b\":2}\n")))
    (should (equal calls '(((b . 2)))))
    (should (equal signel--partial-line ""))))

(ert-deftest signel-filter-oversized-remainder-discarded ()
  (let ((signel--partial-line "")
        (signel-max-line-length 10)
        (calls nil))
    (cl-letf (((symbol-function 'signel--dispatch)
               (lambda (json) (push json calls))))
      (signel--process-filter nil "{\"aaaaaaaaaaaaaaaaaaaa")
      (should (equal signel--partial-line ""))
      (signel--process-filter nil "{\"b\":2}\n"))
    (should (equal calls '(((b . 2)))))))

(ert-deftest signel-log-summary-hides-body ()
  (let ((signel-log-message-bodies nil))
    (should-not (string-match-p "secret"
      (signel--log-summary "SEND" '((method . "send") (id . 1)
                                    (params (message . "secret") (recipient . ["+44"]))))))
    (let ((s (signel--log-summary
              "SEND" '((method . "send") (id . 1)
                       (params (message . "secret") (recipient . ["+44"])
                               (attachments . ["/tmp/pic.png" "/tmp/b.png"]))))))
      (should (string-match-p "method=send" s))
      (should (string-match-p "+44" s))
      (should (string-match-p "attachments=2" s))
      (should-not (string-match-p "pic.png" s)))))

(ert-deftest signel-log-summary-hides-received-content ()
  (let ((signel-log-message-bodies nil))
    (let ((s (signel--log-summary
              "RECV" '((method . "receive")
                       (params (envelope (sourceName . "Alice Secret")
                                         (dataMessage (message . "hello secret")
                                                      (attachments ((filename . "diary.png"))))))))))
      (should (string-match-p "method=receive" s))
      (dolist (w '("Alice" "secret" "diary"))
        (should-not (string-match-p w s))))))

(ert-deftest signel-log-summary-truncates-data-uri ()
  (let ((signel-log-message-bodies t))
    (should (string-match-p "data:<[0-9]+ bytes>"
      (signel--log-summary "SEND" `((params (attachments . [,(concat "data:image/png;base64," (make-string 5000 ?A))]))))))
    (should-not (string-match-p "AAAA"
      (signel--log-summary "SEND" `((params (attachments . [,(concat "data:image/png;base64," (make-string 5000 ?A))]))))))))

(defun signel-test--rpc-roundtrip (reply)
  "Send an RPC with a callback, dispatch REPLY (given the id) twice.
Return the list of (RESULT ERROR) callback invocations."
  (let ((signel--rpc-callbacks (make-hash-table :test 'equal))
        (signel--request-buffer-map (make-hash-table :test 'equal))
        (signel--rpc-id-counter 0)
        (calls nil))
    (cl-letf (((symbol-function 'get-process) (lambda (_) t))
              ((symbol-function 'process-send-string) #'ignore))
      (let* ((id (signel--send-rpc "listContacts" nil nil
                                   (lambda (r e) (push (list r e) calls))))
             (json (cons (cons 'id id) reply)))
        (signel--dispatch json)
        (signel--dispatch json)))
    (nreverse calls)))

(ert-deftest signel-dispatch-calls-result-callback ()
  (should (equal (signel-test--rpc-roundtrip '((result . ((ok . t)))))
                 '((((ok . t)) nil)))))

(ert-deftest signel-dispatch-calls-error-callback ()
  (let ((calls (signel-test--rpc-roundtrip '((error . ((message . "boom")))))))
    (should (= (length calls) 1))
    (should-not (car (car calls)))
    (should (cadr (car calls)))))

;;; Task 8: send status

(ert-deftest signel-send-failures-parses-results ()
  (should (equal (signel--send-failures
                  '((timestamp . 1)
                    (results . [((recipientAddress (uuid . "u1") (number . "+441")) (type . "SUCCESS"))
                                ((recipientAddress (uuid . "u2") (number . nil)) (type . "UNREGISTERED_FAILURE"))])))
                 '("u2: UNREGISTERED_FAILURE"))))

(defmacro signel-test--with-send (&rest body)
  "Run BODY in a chat buffer with RPC stubbed; request id 1 is the send."
  (declare (indent 0) (debug t))
  `(let ((signel--rpc-callbacks (make-hash-table :test 'equal))
         (signel--request-buffer-map (make-hash-table :test 'equal))
         (signel--rpc-id-counter 0))
     (cl-letf (((symbol-function 'get-process) (lambda (_) t))
               ((symbol-function 'process-send-string) #'ignore))
       (signel-test-with-chat "+15550008" ,@body))))

(defun signel-test--type-and-send (text)
  (goto-char (point-max))
  (insert "draft")
  (delete-region signel--input-marker (point-max))
  (insert text)
  (signel--send-input))

(ert-deftest signel-send-shows-pending-then-clears ()
  (signel-test--with-send
    (signel-test--type-and-send "hello")
    (should (string-match-p "<Me> hello (sending…)\n" (buffer-string)))
    (signel--dispatch '((id . 1) (result . ((timestamp . 1)
                                            (results . [((recipientAddress (number . "+1")) (type . "SUCCESS"))])))))
    (should (string-match-p "<Me> hello\n" (buffer-string)))
    (should-not (string-match-p "sending" (buffer-string)))))

(ert-deftest signel-send-shows-partial-failure ()
  (signel-test--with-send
    (signel-test--type-and-send "hello")
    (signel--dispatch '((id . 1) (result . ((results . [((recipientAddress (uuid . "u2")) (type . "NETWORK_FAILURE"))])))))
    (should (string-match-p "hello (not delivered to: u2: NETWORK_FAILURE)\n" (buffer-string)))
    (should-not (string-match-p "ERROR" (buffer-string)))))

(ert-deftest signel-send-shows-rpc-error-once ()
  (signel-test--with-send
    (signel-test--type-and-send "hello")
    (signel--dispatch '((id . 1) (error . ((message . "boom")))))
    (should (string-match-p "hello (failed: boom)\n" (buffer-string)))
    (should-not (string-match-p "\\*\\*\\* ERROR" (buffer-string)))))

(ert-deftest signel-send-status-survives-later-message ()
  (signel-test--with-send
    (signel-test--type-and-send "first")
    (signel--insert-msg "+15550008" "Bob" "incoming" nil nil nil)
    (insert "typing")
    (signel--dispatch '((id . 1) (result . ((results . [((recipientAddress (uuid . "u2")) (type . "X"))])))))
    (should (string-match-p "first (not delivered to: u2: X)\n.*<Bob> incoming\n" (buffer-string)))
    (should (string-suffix-p "typing" (buffer-string)))))

(ert-deftest signel-send-status-ignores-killed-buffer ()
  (signel-test--with-send
    (signel-test--type-and-send "hello")
    (let ((kill-buffer-query-functions nil)) (kill-buffer (current-buffer))))
  (signel--dispatch '((id . 1) (result . ((results . []))))))

(provide 'signel-test)
;;; signel-test.el ends here

;;; Task 3: sanitising and sender identity

(ert-deftest signel-sanitize-strips-controls-and-bidi ()
  (should (equal (signel--sanitize-name "Ali\ne‮fdp.exe") "Aliefdp.exe")))
(ert-deftest signel-sanitize-keeps-unicode ()
  (should (equal (signel--sanitize-name "Zoë 🚣 Ἀθηνᾶ") "Zoë 🚣 Ἀθηνᾶ")))
(ert-deftest signel-sanitize-empty-gives-question-mark ()
  (should (equal (signel--sanitize-name nil) "?"))
  (should (equal (signel--sanitize-name " \t‏ ") "?")))
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
(ert-deftest signel-receive-labels-stranger-with-number-and-escapes-typing ()
  (let ((signel--contacts (make-hash-table :test 'equal))
        (signel--profile-names (make-hash-table :test 'equal))
        (signel--active-chats (make-hash-table :test 'equal)))
    (signel-test-with-chat "+449"
      (cl-letf (((symbol-function 'signel--notify) #'ignore)
                ((symbol-function 'signel--dashboard-refresh) #'ignore)
                ((symbol-function 'display-buffer) #'ignore))
        (signel--handle-receive
         '((envelope . ((sourceNumber . "+449") (sourceUuid . "abcdef12-3456")
                        (sourceName . "100%‮Mum")
                        (dataMessage . ((message . "hi")))))))
        (should (string-match-p "100%Mum (\\+449)" (buffer-string)))
        (signel--handle-receive
         '((envelope . ((sourceNumber . "+449") (sourceName . "100%")
                        (typingMessage . ((action . "STARTED")))))))
        (should (equal mode-line-process " [100%% (+449)...]"))
        (signel--handle-receive
         '((envelope . ((sourceNumber . "+449")
                        (typingMessage . ((action . "STOPPED")))))))
        (should (null mode-line-process))
        (should (equal (gethash "abcdef12-3456" signel--profile-names) "100%Mum"))))))
(ert-deftest signel-receive-blank-source-name-keeps-cached-name ()
  (let ((signel--contacts (make-hash-table :test 'equal))
        (signel--profile-names (make-hash-table :test 'equal))
        (signel--active-chats (make-hash-table :test 'equal)))
    (puthash "+449" "Mum" signel--profile-names)
    (signel-test-with-chat "+449"
      (cl-letf (((symbol-function 'signel--notify) #'ignore)
                ((symbol-function 'signel--dashboard-refresh) #'ignore)
                ((symbol-function 'display-buffer) #'ignore))
        (signel--handle-receive
         '((envelope . ((sourceNumber . "+449") (sourceName . "  ")
                        (dataMessage . ((message . "hi")))))))
        (should (string-match-p "Mum (\\+449)" (buffer-string)))
        (should (equal (gethash "+449" signel--profile-names) "Mum"))))))
(ert-deftest signel-receive-control-only-source-name-keeps-cached-name ()
  (dolist (junk '("‎" "\x01" " ‮\t"))
    (let ((signel--contacts (make-hash-table :test 'equal))
          (signel--profile-names (make-hash-table :test 'equal))
          (signel--active-chats (make-hash-table :test 'equal)))
      (puthash "+449" "Mum" signel--profile-names)
      (signel-test-with-chat "+449"
        (cl-letf (((symbol-function 'signel--notify) #'ignore)
                  ((symbol-function 'signel--dashboard-refresh) #'ignore)
                  ((symbol-function 'display-buffer) #'ignore))
          (signel--handle-receive
           `((envelope . ((sourceNumber . "+449") (sourceName . ,junk)
                          (dataMessage . ((message . "hi")))))))
          (should (string-match-p "Mum (\\+449)" (buffer-string)))
          (should (equal (gethash "+449" signel--profile-names) "Mum")))))))

;;; Task 4: contact list and start-up queue

(ert-deftest signel-load-contacts-rules ()
  (let ((signel--contacts (make-hash-table :test 'equal)))
    (signel--load-contacts
     (vector '((number . "+441") (uuid . "u1") (name . "Mum") (isBlocked . :json-false))
             '((number . "+442") (uuid . "u2") (name . "Ex") (isBlocked . t))
             '((number . "+443") (uuid . "u3") (name . nil) (nickName . nil))
             '((number . nil) (uuid . "u4") (name . "") (nickName . "Bob") (isBlocked . :json-false))
             '((number . "+445") (uuid . "u5") (name . "‮") (nickName . "Al‮") (isBlocked . :json-false))))
    (should (signel--known-contact-p "+441" nil))
    (should (signel--known-contact-p nil "u1"))
    (should-not (signel--known-contact-p "+442" nil))
    (should-not (signel--known-contact-p "+443" nil))
    (should (signel--known-contact-p nil "u4"))
    (should (equal (plist-get (gethash "+445" signel--contacts) :name) "Al"))
    (should-not (signel--known-contact-p "+440" nil))
    (let ((signel-account "+440")) (should (signel--known-contact-p "+440" nil)))))

(defun signel-test--receive-json (n)
  `((method . "receive") (params . ((n . ,n)))))

(defmacro signel-test--with-waiting (var &rest body)
  "Run BODY with receives queued and handled params collected in VAR."
  (declare (indent 1))
  `(let ((signel--contacts (make-hash-table :test 'equal))
         (signel--rpc-callbacks (make-hash-table :test 'equal))
         (signel--contacts-pending t)
         (signel--receive-queue nil)
         (signel--contacts-timer nil)
         (,var nil))
     (cl-letf (((symbol-function 'signel--handle-receive)
                (lambda (p) (push (alist-get 'n p) ,var))))
       ,@body)))

(ert-deftest signel-receives-queued-until-contacts ()
  (signel-test--with-waiting calls
    (puthash 7 #'signel--contacts-reply signel--rpc-callbacks)
    (signel--dispatch (signel-test--receive-json 1))
    (signel--dispatch (signel-test--receive-json 2))
    (should-not calls)
    (signel--dispatch '((id . 7) (result . [((number . "+441") (name . "Mum"))])))
    (should (equal (reverse calls) '(1 2)))
    (should (signel--known-contact-p "+441" nil))
    (signel--dispatch (signel-test--receive-json 3))
    (should (equal (reverse calls) '(1 2 3)))))

(ert-deftest signel-queue-flushes-on-contacts-error ()
  (signel-test--with-waiting calls
    (puthash 7 #'signel--contacts-reply signel--rpc-callbacks)
    (signel--dispatch (signel-test--receive-json 1))
    (signel--dispatch '((id . 7) (error . ((message . "boom")))))
    (should (equal calls '(1)))
    (should-not (signel--known-contact-p "+441" nil))))

(ert-deftest signel-queue-flushes-on-timeout ()
  (signel-test--with-waiting calls
    (signel--dispatch (signel-test--receive-json 1))
    (signel--dispatch (signel-test--receive-json 2))
    (signel--flush-receive-queue)
    (should (equal (reverse calls) '(1 2)))
    (should-not signel--contacts-pending)))

(ert-deftest signel-error-callback-runs-when-handle-error-signals ()
  (let ((signel--rpc-callbacks (make-hash-table :test 'equal)) called)
    (puthash 9 (lambda (_r e) (setq called e)) signel--rpc-callbacks)
    (cl-letf (((symbol-function 'signel--handle-error)
               (lambda (&rest _) (error "handler broke"))))
      (ignore-errors
        (signel--dispatch '((id . 9) (error . ((message . "x")))))))
    (should called)))

(ert-deftest signel-insert-msg-survives-bad-attachment ()
  (signel-test-with-chat "+441"
    ;; A non-string storedFilename makes `file-exists-p' signal.
    (signel--insert-msg "+441" "X" "hi"
                        (vector '((id . "a") (storedFilename . 5) (contentType . "image/png")))
                        nil nil)
    (should (string-match-p "Couldn't display attachment" (buffer-string)))
    (should (string-match-p "hi" (buffer-string)))
    (should (string-suffix-p signel-prompt
                             (buffer-substring-no-properties (point-min) signel--input-marker)))))

(ert-deftest signel-insert-msg-keeps-typed-input ()
  (signel-test-with-chat "+441"
    (goto-char (point-max))
    (insert "half typed")
    (signel--insert-msg "+441" "X" "incoming" nil nil nil)
    (should (equal (buffer-substring-no-properties signel--input-marker (point-max))
                   "half typed"))
    (should (= (point) (point-max)))))

(ert-deftest signel-insert-msg-keeps-point-inside-typed-input ()
  (signel-test-with-chat "+441"
    (goto-char (point-max))
    (insert "half typed")
    (goto-char (+ signel--input-marker 4))
    (signel--insert-msg "+441" "X" "incoming" nil nil nil)
    (should (= (point) (+ signel--input-marker 4)))))

(ert-deftest signel-insert-msg-error-in-media-keeps-prompt ()
  (signel-test-with-chat "+441"
    (goto-char (point-max))
    (insert "typed")
    (cl-letf (((symbol-function 'signel--insert-media)
               (lambda (&rest _) (error "boom"))))
      (ignore-errors
        (signel--insert-msg "+441" "X" "hi" (vector '((id . "a"))) nil nil)))
    (should (string-match-p "hi" (buffer-string)))
    (should (string-suffix-p signel-prompt
                             (buffer-substring-no-properties (point-min) signel--input-marker)))
    (should (equal (buffer-substring-no-properties signel--input-marker (point-max)) "typed"))))

(ert-deftest signel-insert-msg-returns-stable-line-marker ()
  (signel-test-with-chat "+441"
    (let ((m (signel--insert-msg "+441" "X" "first" nil nil nil)))
      (should (markerp m))
      (signel--insert-msg "+441" "X" "second" nil nil nil)
      (goto-char m)
      (should (looking-at-p "\\[[0-9:]+\\] <X> first")))))

(ert-deftest signel-insert-system-msg-keeps-typed-input ()
  (signel-test-with-chat "+441"
    (goto-char (point-max))
    (insert "draft")
    (signel--insert-system-msg "note" 'signel-error-face)
    (should (string-match-p "\\*\\*\\* note" (buffer-string)))
    (should (string-suffix-p signel-prompt
                             (buffer-substring-no-properties (point-min) signel--input-marker)))
    (should (equal (buffer-substring-no-properties signel--input-marker (point-max)) "draft"))))

(ert-deftest signel-receive-data-failure-does-not-stop-typing ()
  (signel-test-with-chat "+441"
    (cl-letf (((symbol-function 'signel--insert-msg) (lambda (&rest _) (error "boom")))
              ((symbol-function 'signel--dashboard-refresh) #'ignore)
              ((symbol-function 'signel--notify) #'ignore))
      (signel--handle-receive
       '((envelope . ((sourceNumber . "+441")
                      (dataMessage . ((message . "hi")))
                      (typingMessage . ((action . "STARTED"))))))))
    (should (string-match-p "\\[" (format "%s" mode-line-process)))))

(ert-deftest signel-insert-msg-partial-line-survives-next-message ()
  (signel-test-with-chat "+441"
    (ignore-errors (signel--insert-msg "+441" "X" nil "notalist" nil nil))
    (signel--insert-msg "+441" "Y" "second" nil nil nil)
    (let ((s (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "<X>" s))
      (should (string-match-p "<Y> second" s))
      (should (string-suffix-p (concat "\n" signel-prompt) s)))))

;;; Task 6: image policy, stickers and animation

(defun signel-test--fixture (bytes &optional suffix)
  "Write BYTES unconverted to a new temp file with SUFFIX; return its name."
  (let ((file (make-temp-file "signel-img" nil suffix))
        (coding-system-for-write 'no-conversion))
    (write-region bytes nil file nil 'silent)
    file))

(defconst signel-test--png "\x89PNG\r\n\x1a\n")
(defconst signel-test--gif "GIF89a")
(defconst signel-test--jpeg "\xff\xd8\xff")
(defconst signel-test--webp "RIFF\0\0\0\0WEBPVP8 ")
(defconst signel-test--svg "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")

(defmacro signel-test--with-image-stubs (calls &rest body)
  "Run BODY with image decoding stubbed; record calls in CALLS.
Each entry is (FUNCTION . ARGS), most recent first."
  (declare (indent 1))
  `(let ((,calls nil))
     (cl-letf (((symbol-function 'create-image)
                (lambda (&rest args) (push (cons 'create-image args) ,calls)
                  (list 'image :type (nth 1 args))))
               ((symbol-function 'insert-image)
                (lambda (&rest args) (push (cons 'insert-image args) ,calls)
                  (insert "<IMG>")))
               ((symbol-function 'image-multi-frame-p)
                (lambda (&rest args) (push (cons 'image-multi-frame-p args) ,calls) t))
               ((symbol-function 'image-size)
                (lambda (&rest args) (push (cons 'image-size args) ,calls) '(1 . 1)))
               ((symbol-function 'image-animate)
                (lambda (&rest args) (push (cons 'image-animate args) ,calls)))
               ((symbol-function 'signel--convert-apng-to-gif)
                (lambda (&rest args) (push (cons 'convert args) ,calls) nil)))
       ,@body)))

(defun signel-test--called (calls fn)
  "Return the entries in CALLS for FN."
  (seq-filter (lambda (c) (eq (car c) fn)) calls))

(ert-deftest signel-image-action-table ()
  (let ((signel-auto-display-images t))
    (should (eq (signel--image-action 'png t nil) 'inline))
    (should (eq (signel--image-action 'jpeg t nil) 'inline))
    (should (eq (signel--image-action 'gif t nil) 'inline))
    (should (eq (signel--image-action 'svg t nil) 'button))
    (should (eq (signel--image-action 'webp t nil) 'button))   ; WebP attachment from contact
    (should (eq (signel--image-action 'webp t t) 'inline))      ; WebP sticker from contact
    (should (eq (signel--image-action 'png nil nil) 'button))   ; stranger
    (should (eq (signel--image-action 'webp nil t) 'button))
    (should (eq (signel--image-action nil t nil) 'file))
    (should (eq (signel--image-action 'postscript t nil) 'file))  ; never rendered
    (should (eq (signel--image-action 'postscript t t) 'file))
    (should (eq (signel--image-action 'postscript nil nil) 'file)))
  (let ((signel-auto-display-images nil))
    (should (eq (signel--image-action 'postscript t nil) 'file))
    (should (eq (signel--image-action 'png t nil) 'button))
    (should (eq (signel--image-action 'webp t t) 'button))
    (should (eq (signel--image-action nil t nil) 'file))))

(ert-deftest signel-sniff-ignores-mime ()
  (let ((files (list (cons (signel-test--fixture signel-test--svg ".png") 'svg)
                     (cons (signel-test--fixture signel-test--png ".svg") 'png)
                     (cons (signel-test--fixture signel-test--gif ".jpg") 'gif)
                     (cons (signel-test--fixture signel-test--jpeg ".gif") 'jpeg)
                     (cons (signel-test--fixture signel-test--webp ".png") 'webp)
                     (cons (signel-test--fixture "hello, world\n" ".png") nil))))
    (unwind-protect
        (dolist (f files)
          (should (eq (signel--sniff-image-type (car f)) (cdr f))))
      (dolist (f files) (delete-file (car f))))
    (should-not (signel--sniff-image-type "/nonexistent/signel/x.png"))))

(defun signel-test--receive-image (group-id source bytes &optional sticker)
  "Receive a group message from SOURCE with an attachment of BYTES.
With STICKER non-nil, send BYTES as a sticker instead.  Return the
fixture file name."
  (let ((file (signel-test--fixture bytes)))
    (cl-letf (((symbol-function 'signel--notify) #'ignore)
              ((symbol-function 'signel--dashboard-refresh) #'ignore)
              ((symbol-function 'display-buffer) #'ignore)
              ((symbol-function 'signel--find-sticker) (lambda (&rest _) file)))
      (signel--handle-receive
       `((envelope . ((sourceNumber . ,source)
                      (dataMessage
                       . ((groupInfo . ((groupId . ,group-id)))
                          ,(if sticker
                               '(sticker . ((packId . "p") (stickerId . 1) (emoji . "🐱")))
                             `(attachments . [((id . "a1") (contentType . "image/png")
                                               (filename . "cat.png")
                                               (storedFilename . ,file))]))))))))
      file)))

(ert-deftest signel-group-stranger-gets-button ()
  (let ((signel--contacts (make-hash-table :test 'equal))
        (signel--profile-names (make-hash-table :test 'equal))
        (signel--active-chats (make-hash-table :test 'equal))
        (signel-auto-display-images t)
        (signel-account "+440"))
    (puthash "+441" '(:name "Mum" :blocked nil) signel--contacts)
    (signel-test-with-chat "GROUPID=="
      (signel-test--with-image-stubs calls
        (let ((file (signel-test--receive-image "GROUPID==" "+449" signel-test--png)))
          (unwind-protect
              (progn
                (should (string-match-p "\\[Show image\\]" (buffer-string)))
                (should-not (string-match-p "<IMG>" (buffer-string)))
                (dolist (fn '(create-image insert-image image-multi-frame-p
                              image-size image-animate convert))
                  (should-not (signel-test--called calls fn))))
            (delete-file file)))))))

(ert-deftest signel-group-stranger-sticker-gets-button ()
  (let ((signel--contacts (make-hash-table :test 'equal))
        (signel--profile-names (make-hash-table :test 'equal))
        (signel--active-chats (make-hash-table :test 'equal))
        (signel-auto-display-images t))
    (puthash "+441" '(:name "Mum" :blocked nil) signel--contacts)
    (signel-test-with-chat "GROUPID=="
      (signel-test--with-image-stubs calls
        (let ((file (signel-test--receive-image "GROUPID==" "+449" signel-test--png t)))
          (unwind-protect
              (progn
                (should (string-match-p "\\[Show sticker 🐱\\]" (buffer-string)))
                (should-not calls))
            (delete-file file)))))))

(ert-deftest signel-group-contact-image-inline-from-data ()
  (let ((signel--contacts (make-hash-table :test 'equal))
        (signel--profile-names (make-hash-table :test 'equal))
        (signel--active-chats (make-hash-table :test 'equal))
        (signel-auto-display-images t))
    (puthash "+441" '(:name "Mum" :blocked nil) signel--contacts)
    (signel-test-with-chat "GROUPID=="
      (signel-test--with-image-stubs calls
        (let ((file (signel-test--receive-image "GROUPID==" "+441" signel-test--png)))
          (unwind-protect
              (let ((ci (car (signel-test--called calls 'create-image))))
                (should (string-match-p "<IMG>" (buffer-string)))
                (should-not (string-match-p "Show image" (buffer-string)))
                ;; Loaded from the bytes, with an explicit type.
                (should (equal (nth 1 ci) signel-test--png))
                (should (eq (nth 2 ci) 'png))
                (should (nth 3 ci)))
            (delete-file file)))))))

(ert-deftest signel-contact-svg-gets-button ()
  (let ((signel--contacts (make-hash-table :test 'equal))
        (signel--profile-names (make-hash-table :test 'equal))
        (signel--active-chats (make-hash-table :test 'equal))
        (signel-auto-display-images t))
    (puthash "+441" '(:name "Mum" :blocked nil) signel--contacts)
    (signel-test-with-chat "GROUPID=="
      (signel-test--with-image-stubs calls
        (let ((file (signel-test--receive-image "GROUPID==" "+441" signel-test--svg)))
          (unwind-protect
              (progn
                (should (string-match-p "\\[Show image\\]" (buffer-string)))
                (should-not calls))
            (delete-file file)))))))

(ert-deftest signel-show-image-button-renders-in-place ()
  (let ((signel-auto-display-images t)
        (signel-enable-animation t)
        (signel-animation-max-time 7)
        (file (signel-test--fixture signel-test--svg ".png")))
    (unwind-protect
        (signel-test-with-chat "+449"
          (signel-test--with-image-stubs calls
            (signel--insert-msg "+449" "X" "look"
                                (vector `((id . "a") (storedFilename . ,file)))
                                nil nil nil)
            (goto-char (point-max))
            (insert "draft")
            (should-not calls)
            (goto-char (point-min))
            (search-forward "[Show image]")
            (push-button (match-beginning 0))
            (should-not (string-match-p "Show image" (buffer-string)))
            (should (string-match-p "look\n+<IMG>\n" (buffer-string)))
            (let ((ci (car (signel-test--called calls 'create-image))))
              (should (equal (nth 1 ci) signel-test--svg))
              (should (eq (nth 2 ci) 'svg)))
            (should (equal (nth 3 (car (signel-test--called calls 'image-animate))) 7))
            (should (string-suffix-p signel-prompt
                                     (buffer-substring-no-properties
                                      (point-min) signel--input-marker)))
            (should (equal (buffer-substring-no-properties signel--input-marker (point-max))
                           "draft"))))
      (delete-file file))))

(ert-deftest signel-auto-display-off-gives-button-for-contacts ()
  (let ((signel-auto-display-images nil)
        (file (signel-test--fixture signel-test--png)))
    (unwind-protect
        (signel-test-with-chat "+441"
          (signel-test--with-image-stubs calls
            (signel--insert-msg "+441" "Me" nil
                                (vector `((id . "a") (storedFilename . ,file)))
                                nil t t)
            (should (string-match-p "\\[Show image\\]" (buffer-string)))
            (should-not calls)))
      (delete-file file))))

(ert-deftest signel-unsniffable-attachment-keeps-file-button ()
  (let ((file (signel-test--fixture "%PDF-1.4 hello" ".png")))
    (unwind-protect
        (signel-test-with-chat "+449"
          (signel-test--with-image-stubs calls
            (signel--insert-msg "+449" "X" nil
                                (vector `((id . "a") (storedFilename . ,file)
                                          (contentType . "image/png")
                                          (filename . "doc.png")))
                                nil nil t)
            (should (string-match-p "\\[File: doc.png (\\.png)\\]" (buffer-string)))
            (should-not calls)))
      (delete-file file))))

(ert-deftest signel-animation-is-bounded ()
  (let ((signel-enable-animation t)
        (signel-animation-max-time 15)
        (file (signel-test--fixture signel-test--gif)))
    (unwind-protect
        (signel-test-with-chat "+441"
          (signel-test--with-image-stubs calls
            (signel--insert-msg "+441" "Mum" nil
                                (vector `((id . "a") (storedFilename . ,file)))
                                nil nil t)
            (let ((anim (signel-test--called calls 'image-animate)))
              (should (= (length anim) 1))
              (should (equal (nth 3 (car anim)) signel-animation-max-time)))))
      (delete-file file))))

(ert-deftest signel-sticker-apng-converted-gif-deleted-after-load ()
  (let ((signel-enable-animation t)
        (png (signel-test--fixture signel-test--png))
        (gif (signel-test--fixture signel-test--gif ".gif")))
    (unwind-protect
        (signel-test-with-chat "+441"
          (signel-test--with-image-stubs calls
            (cl-letf (((symbol-function 'signel--find-sticker) (lambda (&rest _) png))
                      ((symbol-function 'executable-find)
                       (lambda (p &rest _) (and (equal p "convert") "/usr/bin/convert")))
                      ((symbol-function 'signel--convert-apng-to-gif)
                       (lambda (f) (push (list 'convert f) calls) gif)))
              (signel--insert-msg "+441" "Mum" nil nil
                                  '((packId . "p") (stickerId . 1) (emoji . "🐱"))
                                  nil t)
              (should (signel-test--called calls 'convert))
              (let ((ci (car (signel-test--called calls 'create-image))))
                (should (equal (nth 1 ci) signel-test--gif))
                (should (eq (nth 2 ci) 'gif)))
              (should-not (file-exists-p gif))
              (should (file-exists-p png)))))
      (delete-file png)
      (when (file-exists-p gif) (delete-file gif)))))

(ert-deftest signel-sync-message-is-trusted ()
  (let ((signel--contacts (make-hash-table :test 'equal))
        (signel--active-chats (make-hash-table :test 'equal))
        (signel-auto-display-images t)
        (file (signel-test--fixture signel-test--png)))
    (unwind-protect
        (signel-test-with-chat "+449"
          (signel-test--with-image-stubs calls
            (cl-letf (((symbol-function 'signel--dashboard-refresh) #'ignore))
              (signel--handle-receive
               `((envelope . ((sourceNumber . "+440")
                              (syncMessage
                               . ((sentMessage
                                   . ((destinationNumber . "+449")
                                      (attachments . [((id . "a") (storedFilename . ,file))])))))))))
              (should (string-match-p "<IMG>" (buffer-string))))))
      (delete-file file))))

;;; Received files

(ert-deftest signel-file-label-shows-real-extension ()
  (should (equal (signel--file-label "invoice‮fdp.terminal" "/x/abc.terminal")
                 "[File: invoicefdp.terminal (.terminal)]"))
  (should (equal (signel--file-label "a" "/x/abc")
                 "[File: a (no extension)]")))

(ert-deftest signel-open-attachment-declined-opens-nothing ()
  (let (calls)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
              ((symbol-function 'call-process)
               (lambda (&rest a) (push (cons 'call-process a) calls) 0))
              ((symbol-function 'browse-url-of-file)
               (lambda (&rest a) (push (cons 'browse a) calls))))
      (let ((system-type 'darwin))
        (signel--open-attachment "/x/abc.terminal")))
    (should-not calls)))

(ert-deftest signel-open-attachment-quarantines-on-mac ()
  (let (calls prompt)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (p) (setq prompt p) t))
              ((symbol-function 'call-process)
               (lambda (prog _in _out _disp &rest args)
                 (push (list 'call-process prog args) calls) 0))
              ((symbol-function 'browse-url-of-file)
               (lambda (f) (push (list 'browse f) calls))))
      (let ((system-type 'darwin))
        (signel--open-attachment "/x/abc.terminal")))
    (setq calls (nreverse calls))
    (should (equal (length calls) 2))
    (should (equal (car (nth 0 calls)) 'call-process))
    (should (equal (nth 1 (nth 0 calls)) "xattr"))
    (let ((args (nth 2 (nth 0 calls))))
      (should (equal (seq-take args 2) '("-w" "com.apple.quarantine")))
      (should (string-match-p "\\`0081;[0-9a-f]+;signel;\\'" (nth 2 args)))
      (should (equal (nth 3 args) "/x/abc.terminal")))
    (should (equal (nth 0 (nth 1 calls)) 'browse))
    (should (string-match-p "\\.terminal" prompt))))

(ert-deftest signel-open-attachment-xattr-failure-still-opens ()
  (let (opened)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'call-process)
               (lambda (&rest _) (signal 'file-missing '("no xattr"))))
              ((symbol-function 'browse-url-of-file)
               (lambda (f) (setq opened f))))
      (let ((system-type 'darwin))
        (signel--open-attachment "/x/abc.pdf")))
    (should (equal opened "/x/abc.pdf"))))

(ert-deftest signel-open-attachment-no-xattr-off-mac ()
  (let (xattr opened)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'call-process) (lambda (&rest _) (setq xattr t) 0))
              ((symbol-function 'browse-url-of-file)
               (lambda (f) (setq opened f))))
      (let ((system-type 'gnu/linux))
        (signel--open-attachment "/x/abc.pdf")))
    (should-not xattr)
    (should opened)))

;;; Notifications

(ert-deftest signel-notify-mac-uses-argv ()
  (let (cmd)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest a) (setq cmd (plist-get a :command)) nil))
              ((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/osascript")))
      (let ((system-type 'darwin))
        (signel--notify "Signel: X" "-e do shell script \"rm\"\nhi")))
    (should (equal (seq-take cmd 7)
                   '("osascript" "-e" "on run argv" "-e"
                     "display notification (item 2 of argv) with title (item 1 of argv)"
                     "-e" "end run")))
    (should (equal (nth 7 cmd) "Signel: X"))
    (should-not (string-prefix-p "-" (nth 8 cmd)))
    (should-not (string-match-p "\n" (nth 8 cmd)))
    (should (string-match-p "do shell script" (nth 8 cmd)))))

(ert-deftest signel-notify-truncates-and-guards-title ()
  (let (cmd)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest a) (setq cmd (plist-get a :command)) nil))
              ((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/osascript")))
      (let ((system-type 'darwin))
        (signel--notify "-t" (make-string 500 ?x))))
    (should (string-prefix-p " -" (nth 7 cmd)))
    (should (= (length (nth 8 cmd)) 200))))

(ert-deftest signel-notify-never-signals ()
  (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (error "boom")))
            ((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/osascript")))
    (let ((system-type 'darwin))
      (should-not (signel--notify "t" "b")))))

(ert-deftest signel-notify-missing-osascript-skips ()
  (let (called)
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (setq called t)))
              ((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (let ((system-type 'darwin))
        (signel--notify "t" "b")))
    (should-not called)))

(ert-deftest signel-auto-open-despite-notify-failure ()
  (let ((signel--contacts (make-hash-table :test 'equal))
        (signel--profile-names (make-hash-table :test 'equal))
        (signel--active-chats (make-hash-table :test 'equal))
        (signel-auto-open-buffer t)
        (signel-account "+440")
        displayed)
    (signel-test-with-chat "+15551234"
      (cl-letf (((symbol-function 'signel--notify) (lambda (&rest _) (error "boom")))
                ((symbol-function 'signel--dashboard-refresh) #'ignore)
                ((symbol-function 'display-buffer)
                 (lambda (&rest _) (setq displayed t) nil)))
        (signel--handle-receive
         '((envelope . ((sourceNumber . "+15551234")
                        (dataMessage . ((message . "hi")))))))
        (should displayed)))))

;;; Final review fixes

(ert-deftest signel-start-process-is-noquery ()
  (let ((signel-account "+440")
        (signel-cli-program "signal-cli")
        (signel--request-buffer-map (make-hash-table :test 'equal))
        (signel--rpc-callbacks (make-hash-table :test 'equal))
        (signel--contacts (make-hash-table :test 'equal))
        (signel--contacts-timer nil)
        args)
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) "/bin/signal-cli"))
              ((symbol-function 'get-process) (lambda (&rest _) nil))
              ((symbol-function 'make-process)
               (lambda (&rest a) (setq args a) nil))
              ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
              ((symbol-function 'run-at-time) #'ignore)
              ((symbol-function 'signel--request-contacts) #'ignore)
              ((symbol-function 'message) #'ignore))
      (signel-start))
    (should (eq (plist-get args :noquery) t))))

(ert-deftest signel-send-rpc-omits-nil-params ()
  (let ((signel--rpc-callbacks (make-hash-table :test 'equal))
        (signel--request-buffer-map (make-hash-table :test 'equal))
        (signel--rpc-id-counter 0)
        sent)
    (cl-letf (((symbol-function 'get-process) (lambda (_) t))
              ((symbol-function 'process-send-string)
               (lambda (_ s) (push s sent))))
      (signel--send-rpc "listContacts" nil)
      (signel--send-rpc "send" '((message . "hi"))))
    (should-not (string-match-p "params" (cadr sent)))
    (should (string-match-p "\"method\":\"listContacts\"" (cadr sent)))
    (should (string-match-p "\"params\":{\"message\":\"hi\"}" (car sent)))))

(ert-deftest signel-chat-mode-isolates-bidi-per-line ()
  (signel-test-with-chat "+15550010"
    (should (local-variable-p 'bidi-paragraph-start-re))
    (should (equal bidi-paragraph-start-re "^"))
    (should (local-variable-p 'bidi-paragraph-separate-re))
    (should (equal bidi-paragraph-separate-re "^"))
    (should (local-variable-p 'bidi-paragraph-direction))
    (should (eq bidi-paragraph-direction 'left-to-right))))

(ert-deftest signel-send-input-keeps-draft-without-process ()
  (let (sent)
    (cl-letf (((symbol-function 'get-process) (lambda (_) nil))
              ((symbol-function 'process-send-string)
               (lambda (&rest _) (setq sent t))))
      (signel-test-with-chat "+15550011"
        (goto-char (point-max))
        (insert "my draft")
        (should-error (signel--send-input) :type 'user-error)
        (should (equal (buffer-substring-no-properties
                        signel--input-marker (point-max))
                       "my draft"))
        (should-not (string-match-p "<Me>" (buffer-string)))))
    (should-not sent)))
