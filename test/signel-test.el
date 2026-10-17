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
