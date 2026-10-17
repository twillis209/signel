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

(provide 'signel-test)
;;; signel-test.el ends here
