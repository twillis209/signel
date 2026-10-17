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
      (cl-letf (((symbol-function 'notifications-notify) #'ignore)
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
      (cl-letf (((symbol-function 'notifications-notify) #'ignore)
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
        (cl-letf (((symbol-function 'notifications-notify) #'ignore)
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
    (let ((file (make-temp-file "signel-att")))
      (unwind-protect
          ;; Existing file with a non-string contentType makes `string-prefix-p' signal.
          (signel--insert-msg "+441" "X" "hi"
                              (vector `((id . "a") (storedFilename . ,file) (contentType . 5)))
                              nil nil)
        (delete-file file)))
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
              ((symbol-function 'notifications-notify) #'ignore))
      (signel--handle-receive
       '((envelope . ((sourceNumber . "+441")
                      (dataMessage . ((message . "hi")))
                      (typingMessage . ((action . "STARTED"))))))))
    (should (string-match-p "\\[" (format "%s" mode-line-process)))))
