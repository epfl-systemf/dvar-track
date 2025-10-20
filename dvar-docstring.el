;;; dvar-docstring.el --- Annotate docstring in the source code  -*- lexical-binding: t -*-

(require 'cl-lib)
(require 'dvar-track)

(defun dvar-doc--function-docstring (func &optional start)
  "Return the bound of the docstring of `FUNC' if it is defined in the current buffer.
Search starts from (point-min) by default. Use `START' to specify the start point."
  (cl-assert (symbolp func))
  (if start
      (goto-char start))
  (cl-loop with matched = nil
           with defun-point = 0
           with doc-point = 0
           until (or matched (>= (point) (point-max)))
           do 
           (pcase (save-excursion
                    (condition-case-unless-debug nil
                        (read (current-buffer))
                      (invalid-read-syntax)
                      (end-of-file)))
             ;; match defun with docstring
             ((and `(defun ,fn ,arglist ,doc . ,tail)
                   (guard (and (stringp doc) (eq fn func)))
                   )
              ;; (message "%s docstring %s " (symbol-name fn) doc)
              (setq defun-point (point))
              (down-list)
              (forward-sexp 3)
              (skip-chars-forward " \n\t")
              (setq doc-point (point)
                    matched t)
              (backward-up-list)
              )
             ;; the target function has not docstring
             ((and `(defun ,fn ,arglist . ,tail)
                   (guard (and (eq fn func))))
              (message "%s has not docstring" (symbol-name fn)))
             ;; default
             (_ nil))
           (forward-sexp 1)
           finally return
           (if matched
               (save-excursion
                 (goto-char doc-point)
                 (bounds-of-thing-at-point 'string))
             nil
             )))

(defvar-local dvar-doc--overlays nil "A list of docstring overlays")

(defun dvar-doc--dependencies (fn)
  "Return the dependencies of the function `FN' as a list of symbols"
  (cl-assert (symbolp fn))
  (if dvar-track--symtab
      (if-let ((node (gethash fn dvar-track--symtab)))
          (dvar-track--vars fn node)
        nil)
    nil
    ))

(defun dvar-doc--annotate-dependency ()
  "Display the dependencies after the docstrings of functions in the current buffer."
  (interactive)
  (let ((filename (buffer-file-name (current-buffer))))
    (unless (and dvar-track--filetab (gethash filename dvar-track--filetab))
      (dvar-track--scan-files (buffer-file-name (current-buffer)))))

  (let ((fns (gethash (buffer-file-name (current-buffer)) dvar-track--filetab)))
    (dolist (fn fns)
      (when-let ((doc-bound (dvar-doc--function-docstring fn (point-min))))
        (let* ((start (car doc-bound))
               (end (cdr doc-bound))
               (ovl (make-overlay (1+ start) (1- end)))
               (deps (dvar-doc--dependencies fn)))
          (overlay-put ovl 'after-string
                       (concat "\nDependencies:\n " (mapconcat #'symbol-name deps "\n "))) 
          (push ovl dvar-doc--overlays)
          )))))

(defun dvar-doc--clear-overlays ()
  "Clear overlays in the current buffer"
  (while dvar-doc--overlays
    (delete-overlay (pop dvar-doc--overlays))))

(define-minor-mode dvar-docstring-mode
  "Display the dependencies of functions in the current buffer."
  :global nil
  :init-value nil
  :lighter "dvar-doc"
  
  (if dvar-docstring-mode
      (progn
        (dvar-doc--annotate-dependency)
        (message "Enabled dvar-docstring-mode"))
    (progn
      (dvar-doc--clear-overlays)
      (message "Disabled dvar-docstring-mode"))
    ))

(defvar dvar-doc-automatically-parse nil
  "When non-nil, automaically scan the source code if the function is not
in the cache.")

(defun dvar-doc--find-function-file (fn)
  (if (and (symbolp fn) (functionp fn))
      (find-lisp-object-file-name fn 'defun)
    (message "wrong type: fn must be a symbol of a function")))

(defun dvar-doc--insert-report-with-cache (fn)
  (when (and dvar-doc-automatically-parse
             (or (null dvar-track--symtab)
                 (null (gethash fn dvar-track--symtab nil))))
    (apply #'dvar-track--scan-files (dvar-doc--find-function-file fn)))
  (when (hash-table-p dvar-track--symtab)
    (let* ((node (dvar-track--node fn))
           (vars (sort (dvar-track--vars fn node))))
      (insert "Dependencies:\n")
      (dolist (dep vars)
        (insert "** " (symbol-name dep) "\n")))))

(defun dvar-doc--describe-function-1-advice (fn)
  (dvar-doc--insert-report-with-cache fn))

(defun dvar-doc-toggle-help-annotation ()
  (interactive)
  (if (advice-function-member-p #'dvar-doc--describe-function-1-advice
                                (indirect-function #'describe-function-1))
      (progn 
        (advice-remove #'describe-function-1 #'dvar-doc--describe-function-1-advice)
        (message "disabled help annotation"))
    (progn
      (advice-add #'describe-function-1 :after #'dvar-doc--describe-function-1-advice)
      (message "enabled help annotation")
      )))

(provide 'dvar-docstring)
