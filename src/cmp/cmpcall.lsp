;;;;  CMPCALL  Function call.

;;;;  Copyright (c) 1984, Taiichi Yuasa and Masami Hagiya.
;;;;  Copyright (c) 1990, Giuseppe Attardi.
;;;;
;;;;    This program is free software; you can redistribute it and/or
;;;;    modify it under the terms of the GNU Library General Public
;;;;    License as published by the Free Software Foundation; either
;;;;    version 2 of the License, or (at your option) any later version.
;;;;
;;;;    See file '../Copyright' for full details.


(in-package "COMPILER")

(defun fast-link-proclaimed-type-p (fname &optional args)
  (and *compile-to-linking-call*
       (symbolp fname)
       (and (< (the fixnum (length args)) 10)
            (or (and (get-sysprop fname 'FIXED-ARGS)
                     (listp args))
                (and
                 (get-sysprop fname 'PROCLAIMED-FUNCTION)
                 (eq (get-sysprop fname 'PROCLAIMED-RETURN-TYPE) t)
                 (every #'(lambda (v) (eq v t))
                        (get-sysprop fname 'PROCLAIMED-ARG-TYPES)))))))

;;; Like macro-function except it searches the lexical environment,
;;; to determine if the macro is shadowed by a function or a macro.
(defun cmp-macro-function (name)
  (or (sch-local-macro name)
      (macro-function name)))

(defun c1funob (fun &aux fd function)
  ;; fun is an expression appearing in functional position, in particular
  ;; (FUNCTION (LAMBDA ..))
  (when (and (consp fun)
	     (symbolp (first fun))
	     (cmp-macro-function (first fun)))
    (setq fun (cmp-macroexpand fun)))
  (cond ((not (and (consp fun)
		   (eq (first fun) 'FUNCTION)
		   (consp (cdr fun))
		   (endp (cddr fun))))
	 (let ((x (c1expr fun)) (info (make-info :sp-change t)))
	   (add-info info (second x))
	   (list 'ORDINARY info x)))
	((si::valid-function-name-p (setq function (second fun)))
	 (or (c1call-local function)
	     (list 'GLOBAL
		   (make-info :sp-change
			      (not (get-sysprop function 'NO-SP-CHANGE)))
		   function)))
	((and (consp function)
	      (eq (first function) 'LAMBDA)
	      (consp (rest function)))
	 ;; Don't create closure boundary like in c1function
	 ;; since funob is used in this same environment
	 (let ((lambda-expr (c1lambda-expr (rest function))))
	   (list 'LAMBDA (second lambda-expr) lambda-expr (next-cfun))))
	((and (consp function)
	      (eq (first function) 'LAMBDA-BLOCK)
	      (consp (rest function)))
	 ;; Don't create closure boundary like in c1function
	 ;; since funob is used in this same environment
	 (let* ((block-name (second function)))
	   (let ((lambda-expr (c1lambda-expr (cddr function) block-name)))
	     (list 'LAMBDA (second lambda-expr) lambda-expr (next-cfun)))))
	(t (cmperr "Malformed function: ~A" fun))))

(defun c1funcall (args)
  (when (endp args) (too-few-args 'FUNCALL 1 0))
  (let ((fun (first args))
	(arguments (rest args)))
    (cond ((and (consp fun)
		(eq (first fun) 'LAMBDA))
	   (c1expr (optimize-funcall/apply-lambda (cdr fun) arguments nil)))
	  ((and (consp fun)
		(eq (first fun) 'LAMBDA-BLOCK))
	   (setf fun (macroexpand-1 fun))
	   (c1expr (optimize-funcall/apply-lambda (cdr fun) arguments nil)))
	  ((and (consp fun)
		(eq (first fun) 'FUNCTION)
		(consp (second fun))
		(member (caadr fun) '(LAMBDA LAMBDA-BLOCK)))
	   (c1funcall (list* (second fun) arguments)))
	  (t
	   (let ((info (make-info)))
	     (setq fun (c1funob fun))
	     (add-info info (second fun))
	     (list 'FUNCALL info fun (c1args arguments info)))))))

(defun c2funcall (funob args &optional loc narg
			&aux (form (third funob)))
  ;; Usually, ARGS holds a list of forms, which are arguments to the
  ;; function.  If, however, the arguments are on VALUES,
  ;; ARGS should be set to the symbol ARGS-PUSHED, and NARG to a location
  ;; containing the number of arguments.
  ;; LOC is the location of the function object (created by save-funob).
  (case (first funob)
    (GLOBAL (c2call-global form args loc t narg))
    (LOCAL (c2call-local form args narg))
    (LAMBDA (c2call-lambda form args (fourth funob) narg))
    (ORDINARY		;;; An ordinary expression.  In this case, if
              		;;; arguments are already on VALUES, then
              		;;; LOC cannot be NIL.  Callers of C2FUNCALL must be
              		;;; responsible for maintaining this condition.
     (let ((fun (third form)))
       (unless loc
	 (cond ((eq (first form) 'LOCATION) (setq loc fun))
	       ((and (eq (first form) 'VAR)
		     (not (var-changed-in-forms fun args)))
		(setq loc fun))
	       (t
		(setq loc (make-temp-var))
		(let ((*destination* loc)) (c2expr* form)))))

       (let ((*inline-blocks* 0))
	 (c2call-unknown-global nil (if (eq args 'ARGS-PUSHED)
					args
					(inline-args args)) loc nil narg)
	 (close-inline-blocks))))
    (otherwise (baboon))
    ))

(defun c2call-lambda (lambda-expr args cfun &optional narg)
  ;; ARGS is either the list of arguments or 'ARGS-PUSHED
  ;; NARG is a location containing the number of ARGS-PUSHED
  (let ((lambda-list (third lambda-expr))
	(args-pushed (eq 'ARGS-PUSHED args)))
    (if (or (second lambda-list)		;;; Has optional?
	    (third lambda-list)			;;; Has rest?
	    (fourth lambda-list)		;;; Has key?
	    args-pushed				;;; Args already pushed?
	    )
	(let* ((requireds (first lambda-list))
	       (nreq (length requireds))
	       (nopt (if args-pushed narg (- (length args) nreq)))
	       (*unwind-exit* *unwind-exit*))
	  (wt-nl "{ ")
	  (unless args-pushed
	    (setq narg (make-lcl-var :type :cl-index))
	    (wt-nl "cl_index " narg "=0;"))
	  (when requireds
	    (wt-nl "cl_object ")
	    (do ((l requireds (cdr l)))
		((endp l))
	      (setf (var-loc (first l)) (next-lcl))
	      (unless (eq l requireds)
		(wt ", "))
	      (wt (first l)))
	    (wt ";"))
	  (wt-nl "int narg;")
	  (wt-nl "cl_va_list args;")
	  (cond (args-pushed
		 (wt-nl "args[0].sp=cl_stack_index()-" narg ";")
		 (wt-nl "args[0].narg=" narg ";")
		 (dolist (l requireds)
		   (wt-nl l "=cl_va_arg(args);")))
		(t
		 (dolist (l requireds)
		   (let ((*destination* l))
		     (c2expr* (pop args))))
		 (push (list STACK narg) *unwind-exit*)
		 (wt-nl "args[0].sp=cl_stack_index();")
		 (wt-nl "args[0].narg=" nopt ";")
		 (do* ((*inline-blocks* 0)
		       (vals (coerce-locs (inline-args args)) (cdr vals))
		       (i 0 (1+ i)))
		     ((null vals) (close-inline-blocks))
		   (declare (fixnum i))
		   (wt-nl "cl_stack_push(" (first vals) ");")
		   (wt-nl narg "++;"))
		 (wt-nl "args[0].narg=" narg ";")))
	  (wt "narg=" narg ";")
	  (c2lambda-expr lambda-list (third (cddr lambda-expr)) cfun
			 nil nil 'CALL-LAMBDA)
	  (unless args-pushed
	    (wt-nl "cl_stack_pop_n(" narg ");"))
	  (wt-nl "}"))
	(c2let (first lambda-list) args (third (cddr lambda-expr))))))

(defun maybe-push-args (args)
  (when (or (eq args 'ARGS-PUSHED)
	    (< (length args) SI::C-ARGUMENTS-LIMIT))
    (return-from maybe-push-args (values nil nil nil)))
  (let* ((narg (make-lcl-var :type :cl-index)))
    (wt-nl "{cl_index " narg "=0;")
    (let* ((*temp* *temp*)
	   (temp (make-temp-var))
	   (*destination* temp))
      (dolist (expr args)
	(c2expr* expr)
	(wt-nl "cl_stack_push(" temp "); " narg "++;")))
    (values `((STACK ,narg) ,@*unwind-exit*) 'ARGS-PUSHED narg)))

;;;
;;; c2call-global:
;;;   ARGS is either the list of arguments or 'ARGS-PUSHED
;;;   NARG is a location containing the number of ARGS-PUSHED
;;;   LOC is either NIL or the location of the function object
;;;
(defun c2call-global (fname args loc return-type &optional narg)
  (multiple-value-bind (*unwind-exit* args narg)
      (maybe-push-args args)
    (when narg
      (c2call-global fname args loc return-type narg)
      (wt-nl "}")
      (return-from c2call-global)))
  (unless (eq 'ARGS-PUSHED args)
    (case fname
      (AREF
       (let (etype (elttype (info-type (cadar args))))
	 (when (or (and (eq elttype 'STRING)
			(setq elttype 'CHARACTER))
		   (and (consp elttype)
			(or (eq (car elttype) 'ARRAY)
			    (eq (car elttype) 'VECTOR))
			(setq elttype (second elttype))))
	   (setq etype (type-and return-type elttype))
	   (unless etype
	     (cmpwarn "Type mismatch found in AREF. Expected output type ~s, array element type ~s." return-type elttype)
	     (setq etype T))		; assume no information
	   (setf return-type etype))))
      (SYS:ASET				; (sys:aset value array i0 ... in)
       (let (etype
	     (valtype (info-type (cadr (first args))))
	     (elttype (info-type (cadr (second args)))))
	 (when (or (and (eq elttype 'STRING)
			(setq elttype 'CHARACTER))
		   (and (consp elttype)
			(or (eq (car elttype) 'ARRAY)
			    (eq (car elttype) 'VECTOR))
			(setq elttype (second elttype))))
	   (setq etype (type-and return-type (type-and valtype elttype)))
	   (unless etype
	     (cmpwarn "Type mismatch found in (SETF AREF). Expected output type ~s, array element type ~s, value type ~s." return-type elttype valtype)
	     (setq etype T))
	   (setf return-type etype)
	   (setf (info-type (cadr (first args))) etype))))))
  (if (and (inline-possible fname)
	   (not (eq 'ARGS-PUSHED args))
	   *tail-recursion-info*
	   (same-fname-p (first *tail-recursion-info*) fname)
	   (last-call-p)
	   (tail-recursion-possible)
	   (= (length args) (length (cdr *tail-recursion-info*))))
      ;; Tail-recursive case.
      (let* ((*destination* 'TRASH)
	     (*exit* (next-label))
	     (*unwind-exit* (cons *exit* *unwind-exit*)))
	(c2psetq (cdr *tail-recursion-info*) args)
	(wt-label *exit*)
	(unwind-no-exit 'TAIL-RECURSION-MARK)
	(wt-nl "goto TTL;")
	(cmpnote "Tail-recursive call of ~s was replaced by iteration."
		 fname))
      ;; else
      (let ((*inline-blocks* 0))
	(call-global fname (if (eq args 'ARGS-PUSHED) args (inline-args args))
		     loc return-type narg)
	(close-inline-blocks))))

;;;
;;; call-global:
;;;   LOCS is either the list of typed locs with the arguments or 'ARGS-PUSHED
;;;   NARG is a location containing the number of ARGS-PUSHED
;;;   LOC is either NIL or the location of the function object
;;;
(defun call-global (fname locs loc return-type narg &aux found fd maxarg)
  (flet ((emit-linking-call (fname locs narg &aux i)
	   (cond ((null *linking-calls*)
		  (cmpwarn "Emitting linking call for ~a" fname)
		  (push (list fname 0 (add-symbol fname))
			*linking-calls*)
		  (setq i 0))
		 ((setq i (assoc fname *linking-calls*))
		  (setq i (second i)))
		 (t (setq i (1+ (cadar *linking-calls*)))
		    (cmpwarn "Emitting linking call for ~a" fname)
		    (push (list fname i (add-symbol fname))
			  *linking-calls*)))
	   (unwind-exit
	    (call-loc fname (format nil "(*LK~d)" i) locs narg))))
    (cond 
     ;; It is not possible to inline the function call
     ((not (inline-possible fname))
      ;; We can only emit linking calls when function name is a symbol.
      (if (and (symbolp fname) *compile-to-linking-call*)
	(emit-linking-call fname locs narg)
	(c2call-unknown-global fname locs loc t narg)))

     ;; Open-codable function call.
     ((and (not (eq 'ARGS-PUSHED locs))
	   (null loc)
	   (setq loc (inline-function fname locs return-type)))
      (unwind-exit loc))

     ;; Call to a function defined in the same file.
     ((setq fd (assoc fname *global-funs* :test #'same-fname-p))
      (let ((cfun (second fd)))
	(unwind-exit (call-loc fname
			       (if (numberp cfun)
				 (format nil "L~d" cfun)
				 cfun)
			       locs narg))))

     ;; Call to a function whose C language function name is known,
     ;; either because it has been proclaimed so, or because it belongs
     ;; to the runtime.
     ((and (symbolp fname)
	   (or (setq maxarg -1 fd (get-sysprop fname 'Lfun))
	       (multiple-value-setq (found fd maxarg) (si::mangle-name fname t))))
      (multiple-value-bind (val found)
	  (gethash fd *compiler-declared-globals*)
	;; We only write declarations for functions which are not
	;; in lisp_external.h
	(when (and (not found) (not (si::mangle-name fname t)))
	  (wt-h "extern cl_object " fd "();")
	  (setf (gethash fd *compiler-declared-globals*) 1)))
      (unwind-exit
       (if (minusp maxarg)
	 (call-loc fname fd locs narg)
	 (call-loc-fixed fname fd locs narg maxarg))))

     ;; Linking calls can only be made to symbols
     ((and (symbolp fname)
	   *compile-to-linking-call*)	; disabled within init_code
      (emit-linking-call fname locs narg))

     (t (c2call-unknown-global fname locs loc t narg)))
    )
  )

;;; Functions that use SAVE-FUNOB should rebind *temp*.
(defun save-funob (funob)
  (case (first funob)
    ((LAMBDA LOCAL))
    (GLOBAL
     (let ((fun-name (third funob)))
       (unless (and (inline-possible fun-name)
		    (or (and (symbolp fun-name) (get-sysprop fun-name 'Lfun))
			(assoc fun-name *global-funs* :test #'same-fname-p)))
	 (let* ((temp (make-temp-var))
		(fdef (list 'FDEFINITION fun-name)))
	   (wt-nl temp "=" fdef ";")
	   temp))))
    (ORDINARY (let* ((temp (make-temp-var))
                     (*destination* temp))
                (c2expr* (third funob))
                temp))
    (otherwise (baboon))
    ))

;;;
;;; call-loc:
;;;   args are typed locations as produced by inline-args
;;;
(defun call-loc (fname fun args &optional narg-loc)
  (cond ((not (eq 'ARGS-PUSHED args))
	 (list 'CALL fun (length args) (coerce-locs args) fname))
	((stringp fun)
	 (list 'CALL "APPLY" narg-loc (list fun `(STACK-POINTER ,narg-loc))
	       fname))
	(t
	 (list 'CALL "cl_apply_from_stack" narg-loc (list fun) fname))))

(defun call-loc-fixed (fname fun args narg-loc maxarg)
  (cond ((not (eq 'ARGS-PUSHED args))
	 (when (/= (length args) maxarg)
	     (error "Too many arguments to function ~S." fname))
	 (list 'CALL-FIX fun (coerce-locs args) fname))
	((stringp fun)
	 (wt "if(" narg-loc "!=" maxarg ") FEwrong_num_arguments_anonym();")
	 (list 'CALL-FIX "APPLY_fixed" (list fun `(STACK-POINTER ,narg-loc)) fname narg-loc))
	(t
	 (baboon))))

(defun wt-stack-pointer (narg)
  (wt "cl_stack_top-" narg))

(defun wt-call (fun narg args &optional fname)
  (wt fun "(" narg)
  (dolist (arg args)
    (wt "," arg))
  (wt ")")
  (when fname (wt-comment fname)))

(defun wt-call-fix (fun args &optional fname)
  (wt fun "(")
  (when args
    (wt (pop args))
    (dolist (arg args)
      (wt "," arg)))
  (wt ")")
  (when fname (wt-comment fname)))

;;;
;;; c2call-unknown-global
;;;   LOC is NIL or location containing function
;;;   ARGS is either the list of typed locations for arguments or 'ARGS-PUSHED
;;;   NARG is a location containing the number of ARGS-PUSHED
;;;
(defun c2call-unknown-global (fname args loc inline-p narg)
  (unless loc
    (cmpnote "Emiting FDEFINITION call for ~S" fname)
    (setq loc (list 'FDEFINITION fname)))
  (unwind-exit
   (if (eq args 'ARGS-PUSHED)
       (list 'CALL "cl_apply_from_stack" narg (list loc) fname)
       (call-loc fname "funcall" (cons (list T loc) args)))))

;;; ----------------------------------------------------------------------

(put-sysprop 'funcall 'C1 #'c1funcall)
(put-sysprop 'funcall 'c2 #'c2funcall)
(put-sysprop 'call-lambda 'c2 #'c2call-lambda)
(put-sysprop 'call-global 'c2 #'c2call-global)

(put-sysprop 'CALL 'WT-LOC #'wt-call)
(put-sysprop 'CALL-FIX 'WT-LOC #'wt-call-fix)
(put-sysprop 'STACK-POINTER 'WT-LOC #'wt-stack-pointer)
