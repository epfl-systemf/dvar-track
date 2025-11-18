;;; -*- lexical-binding: t -*-

(require 'dvar-track)

(defun dvar-track--dump-dependencies (depsfile sccfile)
  (interactive "FDepFile: \nFSCCFile: ")
  (with-temp-file depsfile
    ;; (cl-assert (null (--filter (not (symbolp (car it))) (map-pairs dvar-track--symtab))))
    (pcase-dolist (`(,func . ,node) (map-pairs dvar-track--symtab))
      (when (dvar-track--visited-p node)
	(prin1 (cons func (dvar-track--node-vars node)) #'insert t)
	(insert "\n")
	)))
  (with-temp-file sccfile
    (mapc (lambda (lst)
	    (prin1 lst #'insert t)
	    (insert "\n"))
	  (hash-table-values dvar-track--sccmember))))

(defun dvar-track--load-record (depsfile)
  (with-temp-buffer
    (insert-file-contents depsfile)
    (goto-char (point-min))
    (let ((record ()))
      (while (condition-case line
		 (read (current-buffer))
	       (:success (push line record))
	       (end-of-file)
	       ((debug error)
		(signal (car line) (cdr line)))))
      (sort record :key #'car :in-place t)
      )))

(defun dvar-track--depdiff (old new)
  "Given two alist of (func . list-of-deps), return a list of (func
list-of-new-deps list-of-disappeared-deps)"
  (let ((old-head old)
	(new-head new)
	(ret ()))
    (while (and old-head new-head)
      (pcase-let ((`(,old-func . ,old-set) (car old-head))
		  (`(,new-func . ,new-set) (car new-head)))
	(if (eq old-func new-func)
	    (progn 
	      (push (list old-func
			  (cl-set-difference new-set old-set :test #'eq :key #'car)
			  (cl-set-difference old-set new-set :test #'eq :key #'car))
		    ret)
	      (setq old-head (cdr old-head)
		    new-head (cdr new-head)))
	  (if (value< old-func new-func)
	      (setq old-head (cdr old-head))
	    (setq new-head (cdr new-head))))))
    (nreverse ret)
    ))

(provide 'dvar-track-evo)
