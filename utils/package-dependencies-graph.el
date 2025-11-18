;;; -*- lexical-binding: t -*-

(require 'package)

(defvar dependency-graph
  (let ((archive package-archive-contents)
	(graph (make-hash-table :test #'eq :size (length package-archive-contents))))
    (pcase-dolist (`(,pkg . ,desc) archive)
      (let ((reqs (package-desc-reqs (car desc))))
	(puthash pkg (mapcar #'car reqs) graph)
	))
    (map-pairs graph)
    ))

(defun trans-dependencies (pkg)
  (let ((deps (assq pkg dependency-graph)))
    (if deps
	(cl-remove-duplicates (--reduce-from (nconc acc (trans-dependencies it)) (cl-copy-list (cdr deps)) (cdr deps)))
      ())))

(defun count-dependencies ()
  (sort (--map (cons (car it) (length (cdr it)))
	     (-group-by #'identity (--mapcat (trans-dependencies (car it)) package-archive-contents)))
      :key #'cdr :reverse t
      ))
