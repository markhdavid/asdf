":" ; exec cl-launch "$0" "$@" # -*- Lisp -*-
#|
Usage: ./tools/asdf-tools install-asdf lispworks
    or l=lispworks ./tools/asdf-tools install-asdf

This script will install the current version of ASDF
as a module pre-compiled for your implementation,
as specified by option -l (--lisp) of cl-launch,
so you can (require "asdf") within your implementation
and have it load a recent ASDF instead of an outdated one.

This file requires cl-launch 4 and works on most implementations.
It notably doesn't work on:
* ABCL, that keeps ASDF in its jar, but that's OK because
 ABCL has a recent enough ASDF3 that is capable of upgrading itself.
* On MKCL and ECL, more work is needed to take into account
 the linkable variant of ASDF, that may be a .o or a .lib.
 Also, MKCL now delivers UIOP separately from ASDF, which is great,
 but requires support. Happily, both ECL and MKCL tend to sport
 a recent ASDF 3, too.
* SBCL since 1.2.2 now like MKCL delivers UIOP separately from ASDF.
* mocl, that doesn't support ASDF 3 yet.
* Corman Lisp, RMCL, Genera, that are obsolete anyway.

|#
;;; Ensure we load and configure this particular ASDF
#-cl-launch
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (member :cl-launch *features*) ;; (not necessary if we're invoked via cl-launch)
    (load (make-pathname
           :name "load-asdf" :type "lisp" :defaults
           (or *compile-file-truename* *load-truename* (truename *default-pathname-defaults*))))))

(in-package :asdf)

(defvar *asdf-dir*
  (ensure-pathname (system-relative-pathname :asdf ())
                   :want-physical t :want-absolute t
                   :want-existing t :truename t))

(defun module-directory ()
  #+allegro #p"sys:code;"
  #+clisp (subpathname custom:*lib-directory* "asdf/")
  #+clozure #p"ccl:tools;"
  #+cmu #p"modules:asdf/"
  #+(or ecl mkcl) #p"sys:"
  #+gcl system:*system-directory*
  #+lispworks (system:lispworks-dir "load-on-demand/utilities/")
  #+sbcl (subpathname (sb-int:sbcl-homedir-pathname) "contrib/")
  #+scl #p"file://modules/"
  #+xcl ext:*xcl-home*
  #-(or allegro clisp clozure cmu ecl gcl lispworks mkcl sbcl scl xcl)
  (error "module-directory not implemented on ~A" (implementation-type)))

(defun module-fasl (name)
  #+allegro
  (flet ((pathname-key (x)
           (let ((type (pathname-type x)))
             (cond
               ((and (stringp type) (every #'digit-char-p type)) (parse-integer type))
               ((equal type "fasl") 0)
               (t -1)))))
    (first (sort (directory (merge-pathnames* (strcat name ".*") (module-directory)))
                 #'> :key #'pathname-key)))
  #+(or clisp clozure cmu ecl gcl lispworks mkcl sbcl scl xcl)
  (compile-file-pathname (subpathname (truename (module-directory)) name :type "lisp"))
  #-(or allegro clisp clozure cmu ecl gcl lispworks mkcl sbcl scl xcl)
  (error "Not implemented on ~A" (implementation-type)))

(defun uiop-module-fasl () (module-fasl "uiop"))
(defun asdf-module-fasl () (module-fasl "asdf"))

(defun object-file (name &optional (type :object))
  #-(or ecl mkcl) (progn name type (assert nil))
  #+ecl (compile-file-pathname name :type type)
  #+mkcl (make-pathname :defaults name :type (bundle-pathname-type type)))

(defun call-with-file-replacement (file thunk)
  (let ((orig (add-pathname-suffix file "-orig")))
    (ensure-directories-exist (translate-logical-pathname file))
    (when (and (probe-file* file) (not (probe-file* orig)))
      (rename-file-overwriting-target file orig))
    (funcall thunk)))

(defmacro with-file-replacement ((file) &body body)
  `(call-with-file-replacement ,file (lambda () ,@body)))

(uiop:uiop-debug)

(defun install-asdf-as-module ()
  (nest
   (let* ((asdf.lisp (system-relative-pathname :asdf-tools "../build/asdf.lisp"))
          (asdf.fasl (asdf-module-fasl))
          #+(or ecl mkcl) (asdf.o (object-file asdf.fasl :object))
          #+(or ecl mkcl) (asdf.a (object-file asdf.fasl :lib))))
   (with-file-replacement (asdf.fasl))
   #+(or ecl mkcl) (with-file-replacement (asdf.o))
   #+(or ecl mkcl) (with-file-replacement (asdf.a))
   (progn
     (compile-file* asdf.lisp :output-file asdf.fasl
                    #+(or ecl mkcl) :object-file #+(or ecl mkcl) asdf.o)
     #+(or ecl mkcl)
     (create-image asdf.a (list asdf.o) :kind :lib))))

(defun install-uiop-and-asdf-as-modules ()
  (let ((uiop.fasl (uiop-module-fasl)))
    (with-file-replacement (uiop.fasl)
      (operate 'compile-bundle-op "uiop")
      (rename-file-overwriting-target (first (output-files 'compile-bundle-op "uiop")) uiop.fasl)
      (load uiop.fasl))
    #+(or ecl mkcl)
    (let ((uiop.a (object-file asdf.fasl :lib)))
      (with-file-replacement (uiop.a)
        (operate 'lib-op "uiop")
        (rename-file-overwriting-target (output-file 'lib-op "uiop") uiop.a)))
  (nest
   (let* ((asdf.fasl (asdf-module-fasl))
          (asdf.lisp (make-pathname :type "lisp" :defaults asdf.fasl))
          #+(or ecl mkcl) (asdf.o (object-file asdf.fasl :object))
          #+(or ecl mkcl) (asdf.a (object-file asdf.fasl :lib))))
   (with-file-replacement (asdf.lisp))
   (with-file-replacement (asdf.fasl))
   #+(or ecl mkcl) (with-file-replacement (asdf.o))
   #+(or ecl mkcl) (with-file-replacement (asdf.a))
   (progn
     (with-output-file (o asdf.lisp :if-exists :rename-and-delete :if-does-not-exist :create)
       (println "(cl:require \"uiop\")" o)
       (dolist (c (component-children (find-system "asdf/defsystem")))
         (with-input-file (i (component-pathname c))
           (copy-stream-to-stream i o))))
     (compile-file* asdf.lisp :output-file asdf.fasl
                    #+(or ecl mkcl) :object-file #+(or ecl mkcl) asdf.o)
     #+(or ecl mkcl)
     (create-image asdf.a (list asdf.o) :kind :lib)))))

#+(or sbcl mkcl)
(progn (install-uiop-and-asdf-as-modules) (quit))
#+(or allegro clisp clozure cmu ecl gcl lispworks scl xcl)
(progn (install-asdf-as-module) (quit))
#+(or abcl cormanlisp genera  mcl mocl)
(die 2 "Not supported on ~A" (implementation-type))
(error "What kind of implementation is THIS?")
