(defun extract-result ()
  (let ((ret ()))
    (maphash (lambda (key val)
               (let ((vars ()))
                 (maphash (lambda (k v)
                            (push k vars))
                          val)
                 (push (cons key vars) ret)))
             dvar-function-dependency)
    ret
    ))

(defun dump-to-file (filename)
  (with-temp-file filename
    (print (extract-result) #'insert)
    ))
