;;; dvar-track.el --- Track dynvar references -*- lexical-binding: t -*-

;; Copyright (C) 2023-2024 Basil L. Contovounesios <basil.contovounesios@epfl.ch>

;; Author: Basil L. Contovounesios <basil.contovounesios@epfl.ch>>
;; Created: 2023-10-16
;; Keywords: internal, lisp, maint
;; Package-Requires: ((emacs "30") ((dash "2.20.0")))
;; URL: https://ic-gitlab.epfl.ch/contovou/track-dynvars
;; Version: 0

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;; TODO:

;; - profile, `define-inline' hot functions
;; - back/quoted forms
;; - how to distinguish lex/var
;; - what to do with require
;; - toplevel non-defuns?

;;; Code:

(require 'map)
(eval-when-compile
  (require 'cl-lib)
  (require 'dash)
  )

(defgroup dvar-track ()
  "Customize group for `dvar-track', a dynvar reference tracker."
  :group 'internal
  :group 'lisp
  :group 'maint
  :prefix "dvar-track-")

(defconst dvar-track--dir (file-name-directory (macroexp-file-name))
  "Root directory of `dvar-track' project.")

(defvar dvar-track--cur-fn nil
  "Name (symbol) of containing function.")

(defvar dvar-track--intros ()
  "Variables introduced in current lexical scope.")

(defvar dvar-track--symtab nil
  "Hash table mapping a function symbol to its `dvar-track--node'.")

(defvar dvar-track--sccmember (make-hash-table :test #'eq)
  "Hash table mapping the root name to members name (including the root)")

(defvar dvar-track--nodes ()
  "Stack of nodes not yet assigned to a SCC.")

(defvar dvar-track--filetab nil
  "Hash table mapping filenames to function symbols in that file.")

(cl-defstruct dvar-track--node
  "AST node holding useful data for function symbols."
  (idx
   nil
   :type (or null natnum)
   :documentation "Unique index of containing SCC, or nil if not yet visited.")
  (root
   nil
   :type symbol
   :documentation "Function symbol of containing SCC root.")
  (vars
   ()
   :type list
   :documentation "Set of dynamic variables referenced in current function.
It should be an alist with the following structure
\='((var1 . (fn1)) (var2 . (fn1 fn2))).  This node depends var1 and var2.
var1 is introduced in this node and var2 is inherited from fn1 and fn2.  Be
careful that multiple functions name ultimately maps to the same SCC."
   ))

(defmacro dvar-track--with-fn (name &rest body)
  "Evaluate BODY under the containing function with NAME."
  (declare (debug t) (indent 1))
  `(let ((dvar-track--cur-fn ,name)) ,@body))

(defmacro dvar-track--with-scope (&rest body)
  "Evaluate BODY in a new lexical scope."
  (declare (debug t) (indent 0))
  `(let ((dvar-track--intros dvar-track--intros)) ,@body))

(defun dvar-track--intro (arg)
  "Add variable ARG to `dvar-track--intros'."
  (cl-pushnew arg dvar-track--intros :test #'eq))

(defun dvar-track--intro-arglist (args)
  "Add variables in ARGS list to `dvar-track--intros'."
  (dolist (arg args)
    (unless (memql (string-to-char (symbol-name arg)) '(?& ?_ 0))
      (dvar-track--intro arg))))

(defun dvar-track--node (fn)
  "Return the canonical `dvar-track--node' for FN symbol."
  (cl-check-type fn symbol)
  (let ((symtab dvar-track--symtab)
        (filetab dvar-track--filetab))
    (or (gethash fn symtab)
        (prog1 (puthash fn (make-dvar-track--node) symtab)
          (let ((file (dvar-track--srcfile fn)))
            (unless (gethash file filetab)
              (puthash file () filetab))
            (cl-pushnew fn (gethash file filetab))))
        )))

(define-inline dvar-track--root-idx (node)
  "Like `dvar-track--node-idx', but NODE can also be a symbol."
  (inline-letevals (node)
    (inline-quote (dvar-track--node-idx
                   (if (symbolp ,node) (dvar-track--node ,node) ,node)))))

(defalias 'dvar-track--visited-p #'dvar-track--root-idx
  "Return non-nil if FN has already been visited.
FN can be either a symbol or a `dvar-track--node'.
\n(fn FN)")

(defun dvar-track--record (var)
  "Record VAR under containing function."
  (let* ((fn dvar-track--cur-fn)
         (node (dvar-track--node fn))
         (vars (dvar-track--node-vars node))
         (samedep (assq var vars)))
    (if samedep
        (cl-pushnew fn (cdr samedep)) ;; track fn also reference var
      (push (cons var (list fn)) (dvar-track--node-vars node))))) ;; new dependency, push (var . (fn)) to vars 
    ;; (unless (memq var (dvar-track--node-vars node))
    ;;   (lwarn 'dvar-track :debug "Vars of `%s': `%s'" fn
    ;;         (push var (dvar-track--node-vars node))))))

(defun dvar-track--var-ref (var)
  "Record VAR, if free, under containing function."
  (and dvar-track--cur-fn ;; TODO: do we care about toplevel forms?
       (not (memq var dvar-track--intros))
       (dvar-track--record var)))

(defun dvar-track--symvar-p (obj)
  "Return non-nil if OBJ is a variable-like symbol."
  (declare (pure t) (side-effect-free error-free))
  (and (symbolp obj)
       (not (booleanp obj))
       (not (keywordp obj))
       (intern-soft obj)
       (not (string= obj ""))))

(defalias 'dvar-track--node-counter
  (let ((i -1)) (lambda (&optional read) (if read i (cl-incf i))))
  "Return a unique node index.
For debugging, non-nil READ returns the current node index instead.
\n(fn &optional READ)")

(defun dvar-track--vars (fn node)
  "Return the list of dynvars referenced by FN and its NODE.
Value represents the entire SCC containing FN and NODE."
  (when-let ((root (dvar-track--node-root node))
             ((not (eq fn root))))
    (cl-assert (null (dvar-track--node-vars node)) t)
    (setq node (dvar-track--node root)))
  ;; (dvar-track--node-vars node)
  (mapcar #'car (dvar-track--node-vars node)) ;; collect keys from alist
  )

;; - Load autoloads
;; - Load (declare-function ... file ...)

(defvar dvar-track--autoreload t)
(defvar dvar-track--reloaded-list ())

(defvar dvar-track--looking-for-path nil "non-nil when we are in the procedure of `dvar-track--find-path-between'")
(defvar dvar-track--looking-for-path-target nil)
(defvar dvar-track--fn-ref-stack () "used to record path in the dfs tree when we are in the procedure of `dvar-track--find-path-between'")

(define-error 'dvar-found-path "Found a path during DFS")

(defun dvar-track--fn-ref (fn)
  "Handle reference to FN definition."
  ;; FIXME: What if it's nil?  E.g. in simple.el:
  ;; (set-process-filter proc #'comint-output-filter)
  ;; without first loading `comint'.
  ;; Load autoloads, etc.

  ;; TODO: compare current environment with the dependencies of fn
  (cl-assert fn)
  (if (not (symbolp fn))
      (dvar-track--recurse fn)
    (let ((fnobj (symbol-function fn)))
      (when (autoloadp fnobj)
        (condition-case nil
            (autoload-do-load fnobj))))
    
    (let ((predecessor dvar-track--cur-fn)
          (node (dvar-track--node fn)))
      
      (when dvar-track--looking-for-path
        (push fn dvar-track--fn-ref-stack)
        (when (eq fn dvar-track--looking-for-path-target)
          (signal 'dvar-found-path dvar-track--fn-ref-stack)))
      
      (unless (dvar-track--visited-p node)
        (when-let* ((fnobj (indirect-function fn))
                    (_needreload-p (subrp fnobj))
                    (def (symbol-function fn))
                    (srcfile (dvar-track--srcfile fn))
                    (_csource-p (not (string-equal-ignore-case "c" (or (file-name-extension srcfile) ""))))
                    (_notpreloaded-p (not (dvar-track--file-preloaded-p srcfile))))
          ;; (append-to-file (format "fn-ref %s reload %s\n" (symbol-name fn) srcfile) nil "~/reloadlog")
          ;; (message "fn-ref %s reload %s" (symbol-name fn) srcfile)
          (let ((load-suffixes (list ".el" ".el.gz")))
            (when dvar-track--autoreload
              (load srcfile 'noerror)
              (push srcfile dvar-track--reloaded-list)
              ))
          ;; (append-to-file (format "reload done") nil "~/reloadlog")
          )
        (let ((fnobj (indirect-function fn)))
          (dvar-track--visit fn fnobj)))
      
      (when dvar-track--looking-for-path
        (pop dvar-track--fn-ref-stack))
      
      (unless (dvar-track--node-root node)
        (cl-assert predecessor)
        (let ((idx (dvar-track--root-idx node)))
          (when (< idx (dvar-track--root-idx predecessor))
            (lwarn 'dvar-track :debug "Setting index of `%s' to `%s'"
                   predecessor fn)
            (setf (dvar-track--root-idx predecessor) idx))))
      (if (not predecessor)
          (lwarn 'dvar-track :debug "Predecessor of `%s' is nil" fn)
        (progn
          (when dvar-track--cur-fn
            (unless (eq fn dvar-track--cur-fn)
              (dvar-track--inherit fn node))
            ;; (let ((deps (dvar-track--vars fn node)))
            ;;  (dvar-lint--record-conflict fn deps)
            ;;  (if dvar-lint--is-funcall (dvar-lint--record-miss fn deps)))
            ))))))

(defun dvar-track--visit (name fn)
  "Visit FN definition with symbol NAME."
  (cl-assert (and name (symbolp name)))
  (let ((dvar-track--cur-fn name)
        (node (dvar-track--node name))
        (idx (dvar-track--node-counter))
        (dvar-track--intros ()) ;; TODO: fix me, check if this is correct added at 10.1.2025
        )
    (setf (dvar-track--node-idx node) idx)
    ;; FIXME: Shouldn't be nil.
    (when fn (dvar-track--fn-ref fn))
    (if (/= (dvar-track--node-idx node) idx)
        (progn
          ;; (lwarn 'dvar-track :debug "Pushing `%s' onto stack" name)
          (push (cons name node) dvar-track--nodes))
      (cl-assert (not (dvar-track--node-root node)))
      (progn
        (setf (dvar-track--node-root node) name)
        (puthash name (list name) dvar-track--sccmember))
      ;; (lwarn 'dvar-track :debug "Started SCC %s" node)
      ;; (when dvar-track--nodes
      ;;   (lwarn 'dvar-track :debug "Stack: `%s'" dvar-track--nodes))
      (while (and dvar-track--nodes
                  (>= (dvar-track--node-idx (cdar dvar-track--nodes)) idx))
        (let ((entry (pop dvar-track--nodes)))
          (lwarn 'dvar-track :debug "Adding `%s' to SCC `%s'" (car entry) name)
          (cl-assert (not (dvar-track--node-root (cdr entry))) t)
          (dvar-track--merge node (cdr entry))
          (progn 
            (setf (dvar-track--node-root (cdr entry)) name)
            (push (car entry) (gethash name dvar-track--sccmember))
            (remhash (car entry) dvar-track--sccmember))
          (setf (dvar-track--node-vars (cdr entry)) ()))))))

(defun dvar-track--recurse (form)
  "Recursively collect dynvar references beneath FORM."
  (pcase form
    ;; Base.
    ((pred null))

    ;; Quoting.
    ;; TODO: `add-hook'?
    (`(function ,fn) (dvar-track--fn-ref fn))
    (`(quote ,(and (pred dvar-track--symvar-p)
                   (or (pred boundp)
                       (pred default-boundp))
                   var))
     (dvar-track--var-ref var))

    ;; Ignore.
    (`(,(or 'quote 'provide 'featurep) . ,_))

    (`(cond . ,clauses)
     (dolist (clause clauses)
       (mapc #'dvar-track--recurse clause)))

    ;; Function definitions.
    (`(,(or 'defalias 'fset) (quote ,name) (function ,fn) . ,_)
     ;; FIXME: Handle redefinitions!
     ;; Are they the same as hooks?
     (unless (dvar-track--visited-p name)
       (dvar-track--visit name fn)))
    (`(closure ,_ ,_ . ,_)
     (cl-assert nil nil "Old closure encountered: %S" form))
    (`(lambda ,arglist . ,tail)
     (dvar-track--with-scope
       (dvar-track--intro-arglist arglist)
       (mapc #'dvar-track--recurse tail)))
    ((pred interpreted-function-p)
     (let ((argdesc (aref form 0))
           (code (aref form 1))
           (constants (aref form 2))
           (interactive (and (length> form 5) (aref form 5))))
       (dvar-track--with-scope
         ;; Empty constants list means function is in dynamically
         ;; scoped dialect.  Ignore?
         (dolist (entry constants)
           (when (consp entry)
             (dvar-track--intro (car entry))))
         ;; ignore interactive forms
         ;; (dvar-track--with-scope
         ;;   (dvar-track--recurse interactive))
         (when (consp argdesc)
           (dvar-track--intro-arglist argdesc))
         (mapc #'dvar-track--recurse code))))

    ;; Variable definitions.
    (`(,(or 'defvar 'defconst) ,_ . ,args)
     (mapc #'dvar-track--recurse args))

    ;; Local bindings.
    (`(let ,varlist . ,body)
     (dvar-track--with-scope
       (dolist (binding varlist)
         (when-let ((val (cdr-safe binding)))
           (dvar-track--recurse (car val))))
       (pcase-dolist ((or `(,var . ,_) var) varlist)
         (dvar-track--intro var))
       (mapc #'dvar-track--recurse body)))
    (`(let* ,varlist . ,body)
     (dvar-track--with-scope
       (pcase-dolist ((or `(,var . ,val) var) varlist)
         (when val (dvar-track--recurse (car val)))
         (dvar-track--intro var))
       (mapc #'dvar-track--recurse body)))
    (`(condition-case ,(or 'nil var) ,body . ,handlers)
     (dvar-track--recurse body)
     (dvar-track--with-scope
       (when var (dvar-track--intro var))
       (pcase-dolist (`(,_ . ,body) handlers)
         (mapc #'dvar-track--recurse body))))

    ;; Setting variables.
    (`(setq . ,args)
     (let (even)
       (dolist (arg args)
         (if (setq even (not even))
             (dvar-track--intro arg)
           (dvar-track--recurse arg)))))
    ;; FIXME: result analysis!
    (`(set ,(or `(make-local-variable (quote ,var))
                `(quote ,var))
           ,val)
     (dvar-track--intro var)
     (dvar-track--recurse val))

    ;; ignore interactive forms
    (`(interactive . ,tail))

    ;; Function application.
    ((or `(,(or 'apply 'funcall 'funcall-interactively)
           (,(or 'function 'quote) ,fn)
           . ,tail)
         `(,(and (or (pred functionp) ;; lambda is included here
                     (and (pred symbolp)
                          (pred fboundp)))
                 fn)
           . ,tail))
     ;; require could be in a function, call require when we see it
     (when (eq fn #'require)
       (condition-case err ;; lack of runtime information the eval resolves to void symbol
           (eval (cons fn tail))
         (t (message "trap error on require %s" (prin1-to-string (cons fn tail) nil t)))
         )
       )
     (mapc #'dvar-track--recurse tail)
     ;; (let ((dvar-lint--is-funcall t))
       (dvar-track--fn-ref fn)
     ;;   )
     )

    ;; Variable reference.
    ((pred dvar-track--symvar-p)
     (dvar-track--var-ref form))))

(defun dvar-track--scan ()
  "Recursively scan current buffer for dynvar references."
  (save-excursion
    (goto-char (point-min))
    (while (condition-case val
               (macroexpand-all (read (current-buffer)))
             (:success (dvar-track--recurse val) t)
             (end-of-file)
             ((debug error)
              (lwarn 'dvar-track :error "Parse error: %S" val)
              nil)))))

(defun dvar-track--prepopulate ()
  "Prepopulate some built-in function-variable dependencies."
  (dolist (fn (list #'prin1 #'prin1-to-string))
    (dvar-track--with-fn fn
      (mapc #'dvar-track--record
            '(float-output-format
              print-charset-text-property
              print-circle
              print-continuous-numbering
              print-escape-control-characters
              print-escape-multibyte
              print-escape-newlines
              print-escape-nonascii
              print-gensym
              print-integers-as-characters
              print-length
              print-level
              print-number-table
              print-quoted
              print-unreadable-function)))))

(defun dvar-track--load-el (&rest args)
  "Like `load', but with a prepared (as in the piano) `load-suffixes'."
  (let ((load-suffixes (cons ".el" (remove ".el" load-suffixes))))
    (apply #'load args)))

(defun dvar-track--preload-els ()
  "Bootstrap ability to load preloaded .el files."
  ;; Work around bug#60346.
  (require 'jka-compr)
  ;; FIXME: Avoid infloop when trying to load `macroexp'.
  ;; See also `preloaded-file-list', loadup.el.
  ;; (dvar-track--load-el "pcase")
  )

(defun dvar-track--clean-cache (file)
  "Remove function nodes of the `FILE'."
  (when-let ((fns (gethash file dvar-track--filetab)))
    (dolist (fn fns)
      (remhash fn dvar-track--symtab))
    (remhash file dvar-track--filetab)
    ))

(defun dvar-track--scan-files (&rest files)
  "Return dynvar reference dependencies for FILES.
Value follows the format of `dvar-track--symtab'."
  (prog1 (or dvar-track--symtab
             (prog1 (setq dvar-track--symtab (make-hash-table :test #'eq))
               (setq dvar-track--filetab (make-hash-table :test #'equal))))
    (let ((dvar-track--cur-fn nil)
          (dvar-track--intros ())
          (dvar-track--nodes ())
          (force-load-messages t)
          (max-lisp-eval-depth 16000))
      (dvar-track--prepopulate)
      (dvar-track--preload-els)
      (dolist (file files)
        ;; FIXME: load deps by source too! bug#60346
        ;; TODO: `load-history', `load-read-function',
        ;; `load-source-file-function'?
        (when (and (not (file-exists-p file))
                   (file-exists-p (concat file ".gz")))
          (setq file (concat file ".gz")))
        ;; (append-to-file (format "scanning %s\n" file) nil "~/scanninglog")
        (unless (dvar-track--file-preloaded-p file)
          (unless (seq-contains-p dvar-track--reloaded-list file #'string-prefix-p)
            (dvar-track--load-el file)
            )
          (dvar-track--clean-cache file)
          (with-temp-buffer
            (insert-file-contents file)
            (dvar-track--scan)))))))

(defconst dvar-track--no-reload-list
  '("loadup.el" "international/characters" "emacs-lisp/macroexp" "emacs-lisp/cconv" "htmlize.el")
  "A list of files should not be autoreloaded. Loading these file leads to
stack overflow.")

(defun dvar-track--file-preloaded-p (file)
  "return t when `file' is loaded"
  (let* ((file (file-truename file))
         (file-san-ext (funcall (-compose #'file-name-sans-extension #'file-name-sans-extension) file))
         (file-base (file-name-base file-san-ext)))
    (--any? (string-match-p file-base it) dvar-track--no-reload-list)
    ))

(defun dvar-track--srcfile (fn)
  "Return the file name defining FN, or \"Unknown\"."
  (or (let ((def (symbol-function fn)))
        (find-lisp-object-file-name fn (if (symbolp def) 'defun def) t))
      (find-lisp-object-file-name fn 'defun t)
      (if (symbolp fn) (symbol-file fn) nil)
      "Unknown"))

(defun dvar-track--report (&rest files)
  "Display dynvar references in FILES in another window."
  (with-current-buffer-window "*dvar-track-report*" () nil
    (pcase-dolist (`(,file . ,deps)
                   (sort (seq-group-by
                          (lambda (dep) (dvar-track--srcfile (car dep)))
                          (map-pairs (apply #'dvar-track--scan-files files)))
                         :key #'car :in-place t))
      (let (heading)
        (pcase-dolist (`(,fn . ,node) (sort deps :key #'car :in-place t))
          (when-let ((vars (dvar-track--vars fn node))
                     (vars (seq-group-by
                            (lambda (var) (and (custom-variable-p var) t))
                            vars)))
            (unless heading
              (insert (format "* %s\n" file))
              (setq heading t))
            (insert (format "** %s\n" fn))
            (dolist (cus '(nil t))
              (when-let ((vars (cdr (assq cus vars))))
                (insert (format "*** %s\n" (if cus "User options" "Variables")))
                (dolist (var (sort vars :in-place t))
                  (insert (format "**** %s\n" var)))))))))
    (goto-char (point-min))
    (outline-mode)))

(defun dvar-track-report (file)
  "Display dynvar references in ELisp FILE in another window.
When called interactively, read FILE with completion."
  (interactive "fScan Elisp file: ")
  (dvar-track--report file))

(defun dvar-track--byte-code (file)
  "Return byte-code object from specification in FILE."
  (let-alist (with-temp-buffer
               (insert-file-contents file)
               (read (current-buffer)))
    (make-byte-code (byte-compile-make-args-desc .args)
                    (byte-compile-lapcode (byte-optimize-lapcode .lap))
                    .vec .depth)))

(defun dvar-track--disassemble-lapcode (file)
  "Disassemble lapcode in FILE."
  (interactive
   (let* ((def (expand-file-name "example/interleave.eld" dvar-track--dir))
          (prompt (format-prompt "Lapcode file" (abbreviate-file-name def))))
     (list (read-file-name prompt (file-name-directory def) def nil nil
                           (lambda (f) (string-suffix-p ".eld" f))))))
  (disassemble (dvar-track--byte-code file)))

(defun dvar-track--clear-all-cache ()
  "Clean caches"
  (interactive)
  (setq dvar-track--cur-fn nil
        dvar-track--intros ()
        dvar-track--symtab nil
        dvar-track--filetab nil
        dvar-track--nodes ()
        ;; dvar-lint--conflicts ()
        ;; dvar-lint--missing ()
        dvar-track--sccmember (make-hash-table :test #'eq)
        )
  (garbage-collect))

(defun dvar-track--samescc-p (fn1 fn2)
  "Return name of the SCC root if `FN1' and `FN2' are in the same SCC."
  (when-let ((node1 (gethash fn1 dvar-track--symtab))
             (node2 (gethash fn2 dvar-track--symtab)))
    (eq (dvar-track--node-root node1) (dvar-track--node-root node2))))

(defun dvar-track--refpath (fn var)
  "Return the path inheritance of dependency on `VARS' in `FN'"
  (cl-assert (symbolp fn))
  (cl-assert (symbolp var))

  (when-let* ((node (gethash fn dvar-track--symtab))
              (root (dvar-track--node-root node)))
    (unless (eq fn root)
      (setq node (gethash root dvar-track--symtab)))

    (let* ((vars (dvar-track--node-vars node))
           (edges (cdr (assq var vars)))
           (sccmem (gethash root dvar-track--sccmember))
           (subpath ()))
      (dolist (nextfn edges)
        (unless (memq nextfn sccmem)
          (push (dvar-track--refpath nextfn var) subpath)))
      (cons sccmem subpath))))

(defun dvar-track--merge (root member)
  "Merge `member''s dependencies into `root'"
  (pcase-dolist (`(,var . ,funcs) (dvar-track--node-vars member))
    (if-let ((existing (assq var (dvar-track--node-vars root))))
        (setf (cdr existing) (cl-union (cdr existing) funcs))
      (push (cons var funcs) (dvar-track--node-vars root)))))

(defun dvar-track--inherit (fn node)
  "Inherit dependencies from `node', if free"
  (when-let ((root (dvar-track--node-root node))
             (_ (not (eq fn root))))
    (setq node (gethash root dvar-track--symtab)))
  (let* ((curfn dvar-track--cur-fn)
         (curnode (and curfn (dvar-track--node curfn)))
         (curvars (and curnode (dvar-track--node-vars curnode))))
    (when curfn
      (pcase-dolist (`(,var . _) (dvar-track--node-vars node))
        (unless (memq var dvar-track--intros)
          (if-let ((curvar (assq var curvars)))
              (cl-pushnew fn (cdr curvar))
            (push (cons var (list fn)) (dvar-track--node-vars curnode))))))))

(defun dvar-track--root (fn)
  "return the root node of the scc of `fn'"
  (if-let ((node (gethash fn dvar-track--symtab)))
      (if (eq (dvar-track--node-root node) fn)
          node
        (gethash (dvar-track--node-root node) dvar-track--symtab))
    nil))

(defun dvar-track--root-sym (fn)
  "return the function symbol of the root of the SCC containing `fn'"
  (if-let ((node (gethash fn dvar-track--symtab)))
      (dvar-track--node-root node)
    nil))

(defvar dvar-track--cur-var nil "var on our focus")

(defun dvar-track--display-leaf (leafsym)
  (insert (concat (symbol-name leafsym)
                  ": "
                  (symbol-name dvar-track--cur-var)
                  "\n")))

(defun dvar-track--dfs (curroot heading)
  "`curroot' must be a root of a SCC"
  (insert (concat heading
                  " "
                  (mapconcat #'symbol-name (gethash curroot dvar-track--sccmember) " ")
                  "\n"))
  (let* ((node (gethash curroot dvar-track--symtab))
         (vars (dvar-track--node-vars node))
         (children (cdr-safe (assq dvar-track--cur-var vars)))
         (sccmems (gethash curroot dvar-track--sccmember))
         (nextlevel ())
         (nextheading (concat heading "*")))
    (dolist (child children)
      (if (memq child sccmems)
          (dvar-track--display-leaf child)
        (cl-pushnew (dvar-track--root-sym child) nextlevel)))
    (dolist (next nextlevel)
      (dvar-track--dfs next nextheading))
    )
  )

(defun dvar-track--traverse-path (fn var)
  "traverse the inheritance of `var' in `fn'"
  (interactive
   (let* ((completion-ignore-case t)
          (fn-at-point (function-called-at-point))
          (fn (completing-read "Function of interest: "
                              dvar-track--symtab
                              nil t
                              (if fn-at-point (symbol-name fn-at-point) "")))
          (var (completing-read "Dependency: "
                                (dvar-track--vars (intern fn) (dvar-track--node (intern fn))))))
     (list (intern fn) (intern var))))
  ;; (interactive "aFunction of interest: \nSDependency of interest: ")
  (cl-assert (symbolp fn))
  (cl-assert (symbolp var))
  (cl-assert (memq var (dvar-track--vars fn (gethash fn dvar-track--symtab))))
  (with-current-buffer-window "*dvar-track-path*" () nil
    (let ((dvar-track--cur-var var))
      (dvar-track--dfs (dvar-track--root-sym fn) "*")
      )
    (goto-char (point-min))
    (outline-mode)
    ))

(defun dvar-track--scan-files-in-directory (target-directory logfile)
  "Scan all el files in TARGET-DIRECTORY. The dependencies of these files
should be in `load-path', so that (require \='feature) should be able to
locate the dependencies." 
  (interactive "Dtarget-directory: \nFlogfile: ")

  (let* ((elfiles (directory-files-recursively target-directory "^[^#\.].*\.el$"))
         (elfiles (--remove (or (string-suffix-p "-pkg.el" it)
                                (string-suffix-p "-autoload.el" it)) elfiles))
         (max-lisp-eval-depth 16000)
         (curindex 0)
         (listsize (length elfiles))
         (dump-log (lambda (msg)
                      (append-to-file (concat msg "\n") nil logfile)
                      (message msg))))
    (dvar-track--clear-all-cache)
    (dolist (els elfiles)
      (cl-incf curindex)
      (garbage-collect)
      (funcall dump-log (format "dvar-track: [%d/%d] scanning %s" curindex listsize els))
      (condition-case-unless-debug errval
          (dvar-track--scan-files els)
        (error (funcall dump-log (format "dvar-track: failed to parse %s %S" els errval)))))
    (funcall dump-log (format "dvar-track: scanned %d files." curindex))))


(defun dvar-track--find-path-between (from-func to-func)
  "find the path from FROM-FUNC to TO-FUNC in the DFS tree. Both parameters should be symbols. *This function ERASE ALL the cache data.*"
  (cl-assert (and (symbolp from-func) (fboundp from-func)))
  (cl-assert (and (symbolp to-func) (fboundp to-func)))
  (dvar-track--clear-all-cache)
  (let ((start-form `(defun dvar-track--dummy () (,from-func))))
    (unless dvar-track--symtab
      (setq dvar-track--symtab (make-hash-table :test #'eq)))
    (unless dvar-track--filetab
      (setq dvar-track--filetab (make-hash-table :test #'equal)))
    (let ((dvar-track--cur-fn nil)
          (dvar-track--intros ())
          (dvar-track--nodes ())
          (force-load-messages t)
          (max-lisp-eval-depth 16000)
          (dvar-track--fn-ref-stack ())
          (dvar-track--looking-for-path t)
          (dvar-track--looking-for-path-target to-func)
          )
      (dvar-track--prepopulate)
      (dvar-track--preload-els)
      (prog1
          (condition-case val
              ;; it is impossible to have an error
              (progn 
                (eval start-form)
                (dvar-track--recurse (macroexpand-all start-form)))  
            (dvar-found-path
             ;; it is a stack, so originally it is '(to-func...from-func)
             (seq-reverse (cdr val)))
            ((debug error)
             (lwarn 'dvar-track :error "Parse error: %S" val)
             nil)
            )
        (fmakunbound #'dvar-track--dummy)
        ))))

(provide 'dvar-track)

;;; dvar-track.el ends here
