;;; -*- lexical-binding: t -*-

(require 'dvar-track)

;; (defun dvar-eldoc--eldoc (callback &rest _ignore)
;;   ""
;;   (let* ((ppss (syntax-ppss (point)))
;;          (toplevelpoint (nth 9 ppss)))
;;     (save-excursion
;;       (goto-char toplevelpoint)
;;       (let (form (read (current-buffer)))
;;         (parse form)
;;         )
;;       )
;;   )

;; ;; from ppss read from the toplevel and do macro expansion 

;;   (dvar-track--node-vars (dvar-track--node #'dvar-track--inherit))

;; (dvar-track--refpath #'dvar-track--inherit 'dvar-track--filetab)

;; (defun my-test-eldoc (callback &rest _ignored)
;;   (let* ((sym-info (elisp--fnsym-in-current-sexp))
;;          (fn-sym (car sym-info)))
;;     (when-let* ((node (dvar-track--node fn-sym)))
;;       (let ((vars (dvar-track--node-vars node)))
;;         (funcall callback
;;                  (mapconcat #'symbol-name (mapcar #'car vars) " ")
;;                  :thing 'dvar-lint
;;                  :face 'font-lock-doc-face)))))

(defun eliminate-syms-with-pos (target-sym form-with-pos)
  (let ((form form-with-pos))
    (cond
     ((eq nil form) nil)
     ((symbolp form) form)
     ((symbol-with-pos-p form)
      (if (eq (bare-symbol form) target-sym)
          form
        (bare-symbol form)))
     ((proper-list-p form) (mapcar (lambda (x) (eliminate-syms-with-pos target-sym x)) form))
     ((consp form) (cons (eliminate-syms-with-pos target-sym (car form))
                         (eliminate-syms-with-pos target-sym (cdr form))))
     ((vectorp form) (seq-into (seq-map (lambda (elm) (eliminate-syms-with-pos target-sym elm)) form) 'vector))
     (t form))))

(defvar tracking-symbol nil)
(defvar tracking-pos 0)
(defvar current-scope ())
(defvar env-intersect nil)

(defmacro with-newscope (&rest body)
  `(let ((current-scope current-scope))
     ,@body))

(defun analyze-recursive (form)
  ""
  (pcase form
    ;; Base.
    ((pred null))

    ;; Quoting.
    ;; TODO: `add-hook'?
    ;; (`(function ,fn) (dvar-track--fn-ref fn))
    (`(quote ,(and (pred dvar-track--symvar-p)
                   (or (pred boundp)
                       (pred default-boundp))
                   var))
     (dvar-track--var-ref var))

    ;; Ignore.
    (`(,(or 'quote 'provide 'featurep) . ,_))

    (`(cond . ,clauses)
     (dolist (clause clauses)
       (mapc #'analyze-recursive clause)))

    ;; Function definitions.
    (`(,(or 'defalias 'fset) (quote ,name) (function ,fn) . ,_)
     ;; FIXME: Handle redefinitions!
     ;; Are they the same as hooks?
     (analyze-recursive fn)
     )
    (`(closure ,_ ,_ . ,_)
     (cl-assert nil nil "Old closure encountered: %S" form))
    (`(lambda ,arglist . ,tail)
     (with-newscope
      (dolist (arg arglist)
        (cl-pushnew arg current-scope :test #'eq))
      (mapc #'analyze-recursive tail)
      ))

    ;; ((pred interpreted-function-p)
    ;;  (let ((argdesc (aref form 0))
    ;;        (code (aref form 1))
    ;;        (constants (aref form 2))
    ;;        (interactive (and (length> form 5) (aref form 5))))
    ;;    (with-newscope
    ;;      ;; Empty constants list means function is in dynamically
    ;;      ;; scoped dialect.  Ignore?
    ;;      (dolist (entry constants)
    ;;        (when (consp entry)
    ;;          (cl-pushnew (car entry) current-scope :test #'eq)
    ;;          ))
    ;;      (with-newscope
    ;;        (analyze-recursive interactive))
    ;;      (when (consp argdesc)
    ;;        (dvar-track--intro-arglist argdesc))
    ;;      (mapc #'dvar-track--recurse code))))

    ;; Variable definitions.
    (`(,(or 'defvar 'defconst) ,_ . ,args)
     (mapc #'analyze-recursive args))

    ;; Local bindings.
    (`(let ,varlist . ,body)
     (with-newscope
       (dolist (binding varlist)
         (when-let ((val (cdr-safe binding)))
           (analyze-recursive (car val))))
       (pcase-dolist ((or `(,var . ,_) var) varlist)
         (cl-pushnew var current-scope :test #'eq))
       (mapc #'analyze-recursive body)))
    (`(let* ,varlist . ,body)
     (with-newscope
       (pcase-dolist ((or `(,var . ,val) var) varlist)
         (when val (analyze-recursive (car val)))
         (cl-pushnew var current-scope :test #'eq))
       (mapc #'analyze-recursive body)))
    
    (`(condition-case ,(or 'nil var) ,body . ,handlers)
     (analyze-recursive body)
     (with-newscope
       (when var (cl-pushnew var current-scope :test #'eq))
       (pcase-dolist (`(,_ . ,body) handlers)
         (mapc #'analyze-recursive body))))

    ;; Setting variables.
    (`(setq . ,args)
     (let (even)
       (dolist (arg args)
         (if (setq even (not even))
             nil
           (analyze-recursive arg)))))
    ;; FIXME: result analysis!
    (`(set ,(or `(make-local-variable (quote ,var))
                `(quote ,var))
           ,val)
     (cl-pushnew var current-scope :test #'eq)
     (analyze-recursive val))

    (`(,(and (pred symbol-with-pos-p) fn) . ,tail)
     (if (and (eq (bare-symbol fn) tracking-symbol)
              (eq (symbol-with-pos-pos fn) tracking-pos))
         (if (not env-intersect)
             (setq env-intersect (cl-copy-list current-scope))
           (setq env-intersect (cl-intersection env-intersect current-scope))))
     (mapc #'analyze-recursive tail)
     )
    ;; Function application.
    ((or `(,(or 'apply 'funcall 'funcall-interactively)
           (,(or 'function 'quote) ,fn)
           . ,tail)
         `(,(and (or (pred functionp) ;; lambda is included here
                     (and (pred symbolp)
                          (pred fboundp)))
                 fn)
           . ,tail))
     (analyze-recursive fn)
     (mapc #'analyze-recursive tail)
     )
    )
  )

(defun funcall-sequence (funcallpoint)
  "return the sequence number (starting from 0) funcall at the point `funcallpoint' of the same function from the toplevel."
  (setq env-intersect nil)
  (save-excursion
    (goto-char funcallpoint)
    (elisp--beginning-of-sexp) ;; move to the funcall of the current sexp
    (let* ((ppss (syntax-ppss (point)))
           (fn (elisp--current-symbol))
           (toplevel (car (nth 9 ppss)))
           (form nil))
      (setq tracking-pos (car (bounds-of-thing-at-point 'symbol))
            tracking-symbol fn)
      (goto-char toplevel)
      (setq form (eliminate-syms-with-pos fn (read-positioning-symbols (current-buffer))))
      (analyze-recursive (macroexpand-all form))
      env-intersect
      )))

(defun dvar-track--missing-binding-eldoc (callback &rest _ignored)
  "Show only missing binding in the echo buffer"
  (when-let* ((sym-info (elisp--fnsym-in-current-sexp))
              (fn-sym (car sym-info))
              ((gethash fn-sym dvar-track--symtab))
              (vars (dvar-track--vars fn-sym (dvar-track--node fn-sym))))
    (let ((missbinding (seq-difference vars (funcall-sequence (point)))))
      (funcall callback
               (format "%s missing bindings: %s"
                       (symbol-name fn-sym)
                       (mapconcat #'symbol-name missbinding " "))
               :thing 'dvar-track
               :face 'font-lock-doc-face))))

(defun dvar-track--test-eldoc ()
  (interactive)
  (dvar-track--missing-binding-eldoc (lambda (str &rest _ignored)
                                       (message str))))

(defun dvar-track--toggle-eldoc ()
  (interactive)
  (if (or (and (symbolp eldoc-documentation-functions)
               (eq #'dvar-track--missing-binding-eldoc eldoc-documentation-functions))
          (and (listp eldoc-documentation-functions)
               (memq #'dvar-track--missing-binding-eldoc eldoc-documentation-functions)))
      (progn (remove-hook 'eldoc-documentation-functions #'dvar-track--missing-binding-eldoc t)
             (message "disable dvar-track-eldoc"))
    (progn (add-hook 'eldoc-documentation-functions #'dvar-track--missing-binding-eldoc nil t)
           (message "enable dvar-track-eldoc"))))

(provide 'dvar-eldoc)
