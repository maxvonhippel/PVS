;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; -*- Mode: Lisp -*- ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; resolve.lisp -- 
;; Author          : Sam Owre
;; Created On      : Thu Dec  9 14:44:26 1993
;; Last Modified By: Sam Owre
;; Last Modified On: Sun Apr  5 01:15:56 1998
;; Update Count    : 38
;; Status          : Beta test
;; 
;; HISTORY
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(in-package 'pvs)

(defvar *resolve-error-info* nil)

(defvar *field-records* nil)

(defvar *get-all-resolutions* nil)

(defvar *typechecking-actual* nil)

;;; Name Resolution

;;; Typechecking a name means to resolve it in its context.  The kind
;;; allows the same name to be used for different purposes, thus a
;;; module named list can have a type named list and a function named
;;; list, since these are of different kinds.  When the kind is 'expr,
;;; the arguments are used to determine the possible types.  The decls
;;; and using provide the search space, decls is the set of declarations
;;; typechecked so far in the current module, and using is the
;;; catenation of the usings preceding the current declaration.  Args
;;; are the actual arguments this name is being applied to.  Note that
;;; 'foo' and 'foo()' are not the same; the former has unspecified
;;; arguments and can be of any type, while the latter has no arguments
;;; and must be of the type 'function[ -> range]'.  Note that typecheck
;;; will complain if there is no resolution, but resolve simply returns
;;; nil; thus resolve can be used to test if a name resolves without
;;; causing an error.

(defmethod typecheck* ((name name) expected kind argument)
  (declare (ignore expected))
  (let* ((*resolve-error-info* nil)
	 (*field-records* nil)
	 (k (or kind 'expr))
	 (args (if (and argument (eq k 'expr))
		   (argument-list argument)
		   argument))
	 (res (resolve* name k args)))
    (when (and (null res)
	       args
	       (eq k 'expr))
      ;; argument-conversion may add to the types of args, and if it returns
      ;; a resolution we are done, otherwise try function-conversion.
      (setq res (or (argument-conversion name args) 
		    (function-conversion name args))))
    (when (memq name *recursive-calls-without-enough-args*)
      (dolist (r res)
	(when (eq (declaration r) (current-declaration))
	  (change-class r 'recursive-function-resolution
			'type (recursive-signature (current-declaration))))))
    (cond ((null res)
	   (resolution-error name k args))
	  ((and (cdr res)
		(not (eq k 'expr)))
	   (let* ((nres (if argument
			    (delete-if-not #'(lambda (r)
					       (formals (declaration r)))
			      res)
			    res))
		  (fres (or (delete-if-not #'fully-instantiated? nres) nres)))
	     (setf (resolutions name) fres)
	     (when (cdr fres)
	       (type-ambiguity name))))
	  (t (setf (resolutions name) res))))
  name)

(defmethod typecheck* ((name modname) expected kind argument)
  (declare (ignore expected kind argument))
  (let ((theory (get-typechecked-theory name)))
    (when (actuals name)
      (unless (= (length (formals-sans-usings theory))
		 (length (actuals name)))
	(type-error name "Wrong number of actuals in ~a" name))
      ;; Skip typechecking if already done.  Note that this has no effect on
      ;; TCCs generated, since set-type-actuals is called in any case.  It
      ;; just keeps actuals from being typechecked to something else.
      ;; This fix is needed because the prover calls typecheck on the
      ;; module-instances it finds to ensure that the proper TCCs are
      ;; generated (see lemma-step).
      (unless (every #'typed? (actuals name))
	(typecheck-actuals name))
      (unless (member name (gethash theory (using-hash *current-context*))
		      :test #'tc-eq)
	(set-type-actuals name)
	(check-compatible-params (formals-sans-usings theory)
				 (actuals name) nil)))
    (when (mappings name)
      (typecheck-mappings (mappings name) name))
    name))

(defmethod module (binding)
  (declare (ignore binding))
  *current-theory*)

(defun resolve* (name kind args)
  (typecheck-actuals name kind)
  (typecheck-mappings (mappings name) name)
  (filter-preferences name (get-resolutions name kind args) kind args))

;;(type-error name "May not provide actuals for entities defined locally")
;;(type-error name "Free variables not allowed here")

(defun get-resolutions (name kind args)
  (let* ((adecls (gethash (id name) (current-declarations-hash)))
	 (ldecls (if (library name)
		     (let ((libref (get-library-reference (library name))))
		       (if libref
			   (remove-if-not
			       #'(lambda (d)
				   (and (library-theory? (module d))
					(string= libref (lib-ref (module d)))))
			     adecls)
			   (type-error name "~a is an unknown library"
				       (library name))))
		     adecls))
	 (decls (if (mod-id name)
		    (remove-if-not
			#'(lambda (d) (eq (id (module d)) (mod-id name)))
		      ldecls)
		    ldecls))
	 (theory-aliases (get-theory-aliases name)))
    (nconc (get-binding-resolutions name kind args)
	   (get-record-arg-resolutions name kind args)
	   (get-decls-resolutions decls (actuals name) (mappings name)
				  kind args)
	   (when (and (eq kind 'module)
		      (null args))
	     (let* ((thname (mk-modname (id name) (actuals name)
					(library name) (mappings name)))
		    (theory (get-theory thname)))
	       (when theory
		 (list (mk-resolution theory thname nil)))))
	   (get-theory-alias-decls-resolutions theory-aliases adecls
					       kind args))))

(defun get-theory-alias-decls-resolutions (theory-aliases adecls kind args
							  &optional reses)
  (if (null theory-aliases)
      reses
      (let* ((thalias (car theory-aliases))
	     (decls (remove-if-not #'(lambda (d)
				       (eq (id (module d)) (id thalias)))
		      adecls))
	     (res (get-decls-resolutions decls (actuals thalias)
					 (mappings thalias) kind args)))
	(get-theory-alias-decls-resolutions
	 (cdr theory-aliases) adecls kind args
	 (nconc reses res)))))

(defun get-theory-aliases (name)
  (when (mod-id name)
    (let ((mod-decls (remove-if-not #'(lambda (d)
					(typep d '(or mod-decl
						      theory-abbreviation-decl
						      formal-theory-decl)))
		       (gethash (mod-id name) (current-declarations-hash)))))
      (get-theory-aliases* mod-decls))))

(defmethod modname ((d formal-theory-decl))
  (theory-name d))

(defmethod theory-name ((d mod-decl))
  (modname d))

(defun get-theory-aliases* (mod-decls &optional modnames)
  (if (null mod-decls)
      (delete-duplicates modnames :test #'tc-eq)
      (get-theory-aliases*
       (cdr mod-decls)
       (let ((thname (theory-name (car mod-decls))))
	 (if (eq (module (car mod-decls)) (current-theory))
	     (nconc (list thname) modnames)
	     (let ((instances (gethash (module (car mod-decls))
				       (current-using-hash))))
	       (nconc modnames
		      (mapcar #'(lambda (inst)
				  (if (actuals inst)
				      (subst-mod-params thname inst)
				      thname))
			instances))))))))

(defmethod get-binding-resolutions ((name name) kind args)
  (with-slots (mod-id library actuals id) name
    (when (and (eq kind 'expr)
	       (null library)
	       (null mod-id)
	       (null actuals))
      (let ((bdecls (remove-duplicates (remove-if-not #'(lambda (bd)
							  (eq (id bd) id))
					 *bound-variables*)
		      :key #'type :test #'compatible? :from-end t)))
	(when bdecls
	  (if args
	      (let ((thinst (current-theory-name)))
		(mapcan #'(lambda (bd)
			    (when (compatible-arguments? bd thinst args
							 (current-theory))
			      (list (mk-resolution bd thinst (type bd)))))
		  bdecls))
	      (mapcar #'(lambda (bd)
			  (mk-resolution bd (current-theory-name) (type bd)))
		bdecls)))))))

(defmethod get-binding-resolutions ((ex number-expr) kind args)
  (when (eq kind 'expr)
    (let ((bdecls (remove-duplicates
		      (remove-if-not #'(lambda (bd)
					 (eq (id bd) (number ex)))
			*bound-variables*)
		    :key #'type :test #'compatible? :from-end t)))
      (when bdecls
	(if args
	    (let ((thinst (current-theory-name)))
	      (mapcan #'(lambda (bd)
			  (when (compatible-arguments? bd thinst args
						       (current-theory))
			    (list (mk-resolution bd thinst (type bd)))))
		bdecls))
	    (mapcar #'(lambda (bd)
			(mk-resolution bd (current-theory-name) (type bd)))
	      bdecls))))))

(defmethod get-record-arg-resolutions ((name name) kind args)
  (with-slots (mod-id library actuals id) name
    (when (and (eq kind 'expr)
	       (null library)
	       (null mod-id)
	       (null actuals)
	       (singleton? args))
      (let ((rtypes (get-arg-record-types (car args))))
	(when rtypes
	  (mapcan #'(lambda (rtype)
		      (let ((fdecl (find-if #'(lambda (fd)
						(eq (id fd) (id name)))
				     (fields rtype))))
			(when fdecl
			  (let ((ftype
				 (if (and (dependent? rtype)
					  (some #'(lambda (x)
						    (and (not (eq x fdecl))
							 (occurs-in x fdecl)))
						(fields rtype)))
				     (let* ((db (mk-dep-binding
						 (make-new-variable '|r| rtype)
						 rtype))
					    (ne (make-dep-field-name-expr
						 db rtype))
					    (ftype (field-application-type
						    (id fdecl) rtype ne)))
				       (mk-funtype db ftype))
				     (mk-funtype (list rtype) (type fdecl)))))
			  (list (make-resolution fdecl (current-theory-name)
						 ftype))))))
	    rtypes))))))

(defmethod get-record-arg-resolutions ((ex number-expr) kind args)
  (declare (ignore kind args))
  nil)

(defun get-arg-record-types (arg)
  (get-arg-record-types* (ptypes arg)))

(defun get-arg-record-types* (types &optional rtypes)
  (if (null types)
      rtypes
      (let ((stype (find-supertype (car types))))
	(get-arg-record-types* (cdr types)
			       (if (typep stype 'recordtype)
				   (cons stype rtypes)
				   rtypes)))))

(defun get-decls-resolutions (decls acts mappings kind args &optional reses)
  (if (null decls)
      reses
      (let ((dreses (get-decl-resolutions (car decls) acts mappings
					  kind args)))
	(get-decls-resolutions (cdr decls) acts mappings kind args
			       (nconc dreses reses)))))


;;; get-decl-resolutions takes a declaration decl, the actuals
;;; acts of the name, the kind, and the args and returns a list
;;; of resolutions.  First a check is made that the decl matches
;;; the kind, is visible, and is not a var-decl outside of a
;;; formula.  If there are args, a check is made that the decl is
;;; a function with the right arity, though if either the args or
;;; the function domain are singletons then it is treated as a
;;; match.

(defun get-decl-resolutions (decl acts mappings kind args)
  (let ((dth (module decl)))
    (when (and (kind-match (kind-of decl) kind)
	       (or (eq dth (current-theory))
		   (and (visible? decl)
			(can-use-for-assuming-tcc? decl)))
	       (not (disallowed-free-variable? decl))
	       (or (null args)
		   (case kind
		     (type (and (formals decl)
				(or (length= (formals decl) args)
				    (singleton? (formals decl))
				    (singleton? args))))
		     (expr (let ((ftype (find-supertype (type decl))))
			     (and (typep ftype 'funtype)
				  (or (length= (domain-types ftype) args)
				      (singleton? (domain-types ftype))
				      (singleton? args)))))
		     (t nil))))
      (if (null acts)
	  (if (and (or (null (formals-sans-usings dth))
		       (eq dth (current-theory)))
		   (null args))
	      (list (mk-resolution decl (mk-modname (id (module decl)))
				   (case kind
				     (expr (type decl))
				     (type (type-value decl)))))
	      (let* ((modinsts (decl-args-compatible? decl args mappings))
		     (unint-modinsts
		      (remove-if
			  #'(lambda (mi)
			      (and (mappings mi)
				   (find decl (mappings mi)
					 :key #'(lambda (m)
						  (and (mapping-def? m)
						       (declaration (lhs m)))))))
			modinsts))
		     (thinsts (if nil ;mappings have already been considered
				  (remove-if-not
				      #'(lambda (mi)
					  (matching-mappings mappings mi))
				    unint-modinsts)
				  unint-modinsts)))
		(mapcar #'(lambda (thinst)
			    (if mappings
				(make-resolution-with-mappings
				 decl thinst mappings)
				(make-resolution decl thinst)))
		  thinsts)))
	  (when (length= acts (formals-sans-usings dth))
	    (let* ((thinsts (gethash dth (current-using-hash)))
		   (genthinst (find-if-not #'actuals thinsts)))
	      (if genthinst
		  (let* ((nacts (compatible-parameters?
				 acts (formals-sans-usings dth)))
			 (dthi (when nacts
				 (mk-modname-no-tccs (id dth) nacts)))
			 (*generate-tccs* 'none))
		    (when dthi
		      (set-type-actuals dthi)
		      #+pvsdebug (assert (fully-typed? dthi))
		      (when (compatible-arguments? decl dthi args
						   (current-theory))
			(list (make-resolution decl dthi)))))
		  (let* ((modinsts (decl-args-compatible? decl args mappings))
			 (thinsts (matching-decl-theory-instances
				   acts dth modinsts)))
		    (when thinsts
		      (mapcar #'(lambda (thinst)
				  (make-resolution decl thinst))
			thinsts))))))))))

(defun matching-decl-theory-instances (acts theory thinsts &optional matches)
  (if (null thinsts)
      (get-best-matching-decl-theory-instances acts (nreverse matches))
      (let ((mthinst (matching-actuals acts theory (car thinsts))))
	(matching-decl-theory-instances acts theory (cdr thinsts)
					(if mthinst
					    (cons mthinst matches)
					    matches)))))

(defun get-best-matching-decl-theory-instances (acts instances)
  (if (cdr instances)
      (get-best-matching-decl-theory-instances* acts instances)
      instances))

(defun get-best-matching-decl-theory-instances* (acts instances
						      &optional (count 0) best)
  (if (null instances)
      (nreverse best)
      (let ((ncount (count-equal-actuals acts (actuals (car instances)))))
	(get-best-matching-decl-theory-instances*
	 acts (cdr instances)
	 (max ncount count)
	 (cond ((< ncount count)
		best)
	       ((> ncount count)
		(list (car instances)))
	       (t (cons (car instances) best)))))))

(defun count-equal-actuals (acts1 acts2 &optional (count 0))
  (if (null acts1)
      count
      (count-equal-actuals
       (cdr acts1) (cdr acts2)
       (if (tc-eq (car acts1) (car acts2))
	   (1+ count)
	   count))))

(defun copy-actuals (acts)
  acts)

(defun make-resolution-with-mappings (decl thinst mappings)
  (if (every #'(lambda (m)
		     (member (lhs m) (mappings thinst)
			     :test #'same-id :key #'lhs))
	     mappings)
      (make-resolution decl thinst)
      (let* ((nmappings (append (mappings thinst) mappings))
	     (nthinst (copy thinst 'mappings nmappings)))
	(typecheck-mappings nmappings nthinst)
	(make-resolution decl nthinst))))
	

(defun decl-args-compatible? (decl args mappings)
  (if (eq (module decl) (current-theory))
      (compatible-arguments? decl (current-theory-name) args (current-theory))
      (let* ((idecls (when mappings
		       (interpretable-declarations (module decl))))
	     (thinsts (when (or (null mappings)
				(every #'(lambda (m)
					   (member (id (lhs m)) idecls
						   :key #'id))
				       mappings))
			(gethash (module decl) (current-using-hash))))
	     (mthinsts (if mappings
			   (create-theorynames-with-name-mappings
			    thinsts mappings)
			   thinsts)))
	(mapcan #'(lambda (thinst)
		    (compatible-arguments?
		     decl thinst args (current-theory)))
	  mthinsts))))

(defun create-theorynames-with-name-mappings (thinsts mappings
						      &optional mthinsts)
  ;; Note that some instances may work, while others won't.
  ;; E.g., given mappings (x := 3), where x and y are interpretable
  ;; in theory th, the instances
  ;;  th, th[int], and th{{y := 4}} works, but
  ;;  th{{x := 4}} will be ignored, since x is no longer interpretable in
  ;; that instance.
  (if (null thinsts)
      (nreverse mthinsts)
      (create-theorynames-with-name-mappings
       (cdr thinsts)
       mappings
       (if (matching-mappings mappings (car thinsts))
	   (let* ((nmappings (copy-all mappings))
		  (nthinst (copy (car thinsts)
			     'mappings (append (mappings (car thinsts))
					       nmappings))))
	     (typecheck-mappings nmappings nthinst)
	     (cons nthinst mthinsts))
	   mthinsts))))

      

;;; This will set the types of the actual parameters.
;;; Name-exprs are typechecked twice; once as an expression and once as
;;; a type.  This is where any restriction of actuals is enforced, as
;;; the grammar allows arbitrary expressions and type expressions.  Note
;;; that the actual parameters must uniquely resolve.

(defun typecheck-actuals (name &optional (kind 'expr))
  (mapc #'(lambda (a) (typecheck* a nil kind nil))
	(actuals name)))

(defmethod typecheck* ((act actual) expected kind arguments)
  (declare (ignore expected kind arguments))
  #+pvsdebug (when (type (expr act)) (break "Type set already???"))
  (unless (typed? act)
    (typecase (expr act)
      (name-expr
       (let* ((name (expr act))
	      (tres (let ((*typechecking-actual* t))
		      (with-no-type-errors (resolve* name 'type nil)))))
	 (multiple-value-bind (eres error obj)
	     (let ((*typechecking-actual* t))
	       (with-no-type-errors (resolve* name 'expr nil)))
	   (declare (ignore error obj))
	   (unless (or tres eres)
	     (resolution-error name 'expr-or-type nil))
	   (if (cdr tres)
	       (cond (eres
		      (setf (resolutions name) eres))
		     (t (setf (resolutions name) tres)
			(type-ambiguity name)))
	       (setf (resolutions name) (nconc tres eres)))
	   (when eres
	     (setf (types (expr act)) (mapcar #'type eres))
	     (when (and (plusp (parens (expr act)))
			(some #'(lambda (ty)
				  (let ((sty (find-supertype ty)))
				    (and (funtype? sty)
					 (tc-eq (find-supertype
						 (range sty))
						*boolean*))))
			      (ptypes (expr act))))
	       (setf (type-value act)
		     (typecheck* (make-instance 'expr-as-type
				   'expr (copy-untyped (expr act)))
				 nil nil nil))))
	   (when tres
	     (if (type-value act)
		 (unless (compatible? (type-value act) (type (car tres)))
		   (push (car tres) (resolutions (expr act)))
		   (type-ambiguity (expr act)))
		 (progn
		   (when (and (mod-id (expr act))
			      (typep (type (car tres)) 'type-name)
			      (same-id (expr act) (type (car tres))))
		     (setf (mod-id (type (car tres)))
			   (mod-id (expr act))))
		   (setf (type-value act) (type (car tres)))
		   (push 'type (types (expr act)))))))))
      ;; with-no-type-errors not needed here;
      ;; the expr typechecks iff the subtype does.
      (set-expr (typecheck* (expr act) nil nil nil)
		(let ((texpr (typecheck* (setsubtype-from-set-expr (expr act))
					 nil nil nil)))
		  (when texpr
		    (setf (type-value act) texpr)
		    (push 'type (types (expr act))))))
      (application
       (multiple-value-bind (ex error obj)
	   (let ((*typechecking-actual* t))
	     (with-no-type-errors (typecheck* (expr act) nil nil nil)))
	 (declare (ignore ex))
	 (cond ((and (zerop (parens (expr act)))
		     (typep (operator (expr act)) 'name))
		(with-no-type-errors
		 (let* ((tn (mk-type-name (operator (expr act))))
			(args (arguments (expr act)))
			(*typechecking-actual* t)
			(tval (typecheck*
			       (make-instance 'type-application
				 'type tn
				 'parameters args)
			       nil nil nil)))
		   (setf (type-value act) tval))))
	       ((and (plusp (parens (expr act)))
		     (some #'(lambda (ty)
			       (let ((sty (find-supertype ty)))
				 (and (funtype? sty)
				      (tc-eq (find-supertype (range sty))
					     *boolean*))))
			   (ptypes (expr act))))
		(setf (type-value act)
		      (typecheck* (make-instance 'expr-as-type
				    'expr (expr act))
				  nil nil nil))))
	 (unless (or (ptypes (expr act))
		     (type-value act))
	   (type-error (or obj (expr act)) error))))
      ;; with-no-type-errors not needed here;
      ;; the expr typechecks iff the expr-as-type does.
      (expr (typecheck* (expr act) nil nil nil)
	    (when (and (plusp (parens (expr act)))
		       (some #'(lambda (ty)
				 (let ((sty (find-supertype ty)))
				   (and (funtype? sty)
					(tc-eq (find-supertype (range sty))
					       *boolean*))))
			     (ptypes (expr act))))
	      (setf (type-value act)
		    (typecheck* (make-instance 'expr-as-type
				  'expr (expr act))
				nil nil nil))))
      ;; Must be a type-expr
      (t (unless (type-value act)
	   (setf (type-value act)
		 (typecheck* (expr act) nil nil nil))))))
  act)

(defun setsubtype-from-set-expr (expr)
  (let ((suptype (declared-type (car (bindings expr)))))
    (assert (typep (car (bindings expr)) 'bind-decl))
    (make-instance 'setsubtype
      'supertype suptype
      'formals (car (bindings expr))
      'formula (expression expr))))

(defun eq-id (x y)
  (eq x (id y)))


;;; At this point, we know that the module has the right id, the
;;; right number of parameters, and that the name and theory
;;; instance have actuals - the generic form of the theory is not
;;; available.  This function tests whether the given theory
;;; instance matches the name by comparing the actuals of the
;;; name with the actuals of the theory instance.

;;; The tricky part here is that the theory instance actuals may contain
;;; formal parameters (not in the current theory).  For example,
;;;  A[T1: TYPE]: THEORY BEGIN a: TYPE END A
;;;  B[T2: TYPE]: THEORY BEGIN IMPORTING A[T2] END B
;;;  C[T3: TYPE]: THEORY BEGIN IMPORTING B; x: a[T3] END C
;;; In this case the theory instance for A in the context of theory C is
;;; A[T2], and we need to substitute (a typechecked copy of) T3 for T2 and
;;; return A[T3].

(defun matching-actuals (actuals theory thinst)
  (let* ((theory-actuals (actuals thinst))
	 (theory-frees (free-params theory-actuals))
	 (current-formals (formals-sans-usings (current-theory))))
    ;; mactuals are fully typechecked, though they may involve
    ;; non-local formal parameters, in which case we need to use
    ;; tc-match; otherwise we simply call matching-actual
    (if (and theory-frees
	     (some #'(lambda (free) (not (memq free current-formals)))
		   theory-frees))
	(matching-actuals-with-nonlocal-formals actuals theory theory-actuals
						theory-frees)
	(when (every #'matching-actual actuals theory-actuals
		     (formals-sans-usings theory))
	  thinst))))

;;; In the example above, actuals = (T3), theory = A,
;;; theory-actuals = (T2), and theory-frees = (T2).  We create
;;; the theory-instance A[T3] by substituting the actuals for the
;;; theory-frees in the theory-instance.  Subst-mod-params
;;; doesn't work here, as it needs the theory instance we're
;;; trying to create.

(defun matching-actuals-with-nonlocal-formals (actuals theory theory-actuals
					       theory-frees)
  (let ((bindings (tc-match actuals theory-actuals
			    (mapcar #'list theory-frees))))
    (when (and bindings
	       (every #'cdr bindings))
      (let* ((sactuals (gensubst theory-actuals
			 #'(lambda (ex)
			     (cdr (assq (declaration ex) bindings)))
			 #'(lambda (ex)
			     (and (name? ex)
				  (assq (declaration ex) bindings)))))
	     (thinst (mk-modname (id theory) sactuals)))
	(with-no-type-errors
	    (typecheck* (pc-parse (unparse thinst :string t) 'modname)
			nil nil nil))))))


;;; compatible-parameters? checks that the actuals and formals of a given
;;; theory are compatible.  The actuals do not have to be fully-typed, but
;;; at least typechecked by typecheck-actuals.  If satisfied, a list of
;;; new actuals is returned that is consistent with the given actuals.

(defun compatible-parameters? (actuals formals)
  (when (length= actuals formals)
    (nreverse (compatible-parameters?* actuals formals))))

(defun compatible-parameters?* (actuals formals &optional nacts alist)
  (if (null actuals)
      nacts
      (multiple-value-bind (nfml nalist)
	  (subst-actuals-in-next-formal (car actuals) (car formals) alist)
	(let ((type (compatible-parameter? (car actuals) nfml)))
	  (and type
	       (if (typep nfml 'formal-type-decl)
		   (compatible-parameters?*
		    (cdr actuals) (cdr formals)
		    (cons (copy-all (car actuals)) nacts) nalist)
		   (compatible-parameters?**
		    actuals formals type nacts nalist)))))))

(defun compatible-parameters?** (actuals formals types nacts alist)
  (when types
    (let ((nact (copy-untyped (car actuals)))
	  (*generate-tccs* 'none))
      (typecheck* nact nil nil nil)
      (set-type (expr nact) (car types))
      (or (unless (cdr actuals)
	    (cons nact nacts))
	  (compatible-parameters?*
	   (cdr actuals) (cdr formals)
	   (cons nact nacts)
	   (acons (car formals) nact (cdr alist)))
	  (compatible-parameters?**
	   actuals formals (cdr types) nacts alist)))))

(defun compatible-parameter? (actual formal)
  (if (formal-type-decl? formal)
      (type-value actual)
      (unless (type-expr? (expr actual))
	(remove-if-not #'(lambda (ptype)
			   (and (type-expr? ptype)
				(compatible? ptype (type formal))))
	      (ptypes (expr actual))))))


;;; matching-actual is called to check that the actual from the
;;; name matches the actual from the theory instance.  This is
;;; essentially tc-eq, but allows for the actual from the name
;;; (the first argument) to have multiple types.  The actual from
;;; the theory instance (the second argument) is fully typed, and
;;; has no free parameters (other than those of the current
;;; theory).  If the name actual has a type-value it is
;;; fully-typed, which is why tc-eq works in this case.

(defun matching-actual (actual mactual formal)
  (if (formal-type-decl? formal)
      (let ((atv (type-value actual)))
	(and atv
	     (tc-eq atv (type-value mactual))))
      (matching-actual-expr (expr actual) mactual)))

(defmethod matching-actual-expr ((aex expr) (maex implicit-conversion))
  (or (call-next-method)
      (matching-actual-expr aex (argument maex))))

(defmethod matching-actual-expr ((aex expr) (maex actual))
  (matching-actual-expr aex (expr maex)))

(defmethod matching-actual-expr ((aex expr) (maex null))
  t)

(defmethod matching-actual-expr ((aex expr) maex)
  (if (type aex)
      (tc-eq aex maex)
      (matching-actual-expr* aex maex nil)))

(defmethod matching-actual-expr (aex maex)
  (declare (ignore aex maex))
  nil)

(defmethod matching-actual-expr* (aex maex bindings)
  (declare (ignore aex maex bindings))
  nil)

(defmethod matching-actual-expr* (aex (maex implicit-conversion) bindings)
  (or (call-next-method)
      (matching-actual-expr* aex (argument maex) bindings)))

(defmethod matching-actual-expr* ((l1 cons) (l2 cons) bindings)
  (matching-actual-expr-lists l1 l2 bindings))

(defun matching-actual-expr-lists (l1 l2 bindings)
  (declare (list l1 l2))
  (cond ((null l1) (null l2))
	((null l2) nil)
	(t (and (matching-actual-expr* (car l1) (car l2) bindings)
		(matching-actual-expr-lists
		 (cdr l1) (cdr l2)
		 (new-tc-eq-list-bindings (car l1) (car l2)
					  bindings))))))

(defmethod matching-actual-expr* ((e1 name-expr) (e2 field-name-expr) bindings)
  (with-slots ((id1 id) (ty1 types)) e1
    (with-slots ((id2 id) (ty2 type)) e2
      (and (eq id1 id2)
	   (some #'(lambda (ty) (tc-eq-with-bindings ty ty2 bindings))
		 ty1)))))

(defmethod matching-actual-expr* ((e1 projection-expr) (e2 projection-expr)
				  bindings)
  (declare (ignore bindings))
  (or (eq e1 e2)
      (with-slots ((id1 index)) e1
	(with-slots ((id2 index)) e2
	  (= id1 id2)))))

(defmethod matching-actual-expr* ((e1 projection-expr) (e2 name-expr)
				  bindings)
  (let ((bind (assoc e2 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* e1 (cdr bind) nil))))

(defmethod matching-actual-expr* ((e1 name-expr) (e2 projection-expr)
				  bindings)
  (let ((bind (assoc e1 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* (cdr bind) e2 nil))))

(defmethod matching-actual-expr* ((e1 injection-expr) (e2 injection-expr)
				  bindings)
  (declare (ignore bindings))
  (or (eq e1 e2)
      (with-slots ((id1 index)) e1
	(with-slots ((id2 index)) e2
	  (= id1 id2)))))

(defmethod matching-actual-expr* ((e1 injection-expr) (e2 name-expr)
				  bindings)
  (let ((bind (assoc e2 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* e1 (cdr bind) nil))))

(defmethod matching-actual-expr* ((e1 name-expr) (e2 injection-expr)
				  bindings)
  (let ((bind (assoc e1 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* (cdr bind) e2 nil))))

(defmethod matching-actual-expr* ((e1 injection?-expr) (e2 injection?-expr)
				  bindings)
  (declare (ignore bindings))
  (or (eq e1 e2)
      (with-slots ((id1 index)) e1
	(with-slots ((id2 index)) e2
	  (= id1 id2)))))

(defmethod matching-actual-expr* ((e1 injection?-expr) (e2 name-expr)
				  bindings)
  (let ((bind (assoc e2 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* e1 (cdr bind) nil))))

(defmethod matching-actual-expr* ((e1 name-expr) (e2 injection?-expr)
				  bindings)
  (let ((bind (assoc e1 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* (cdr bind) e2 nil))))

(defmethod matching-actual-expr* ((e1 extraction-expr) (e2 extraction-expr)
				  bindings)
  (declare (ignore bindings))
  (or (eq e1 e2)
      (with-slots ((id1 index)) e1
	(with-slots ((id2 index)) e2
	  (= id1 id2)))))

(defmethod matching-actual-expr* ((e1 extraction-expr) (e2 name-expr)
				  bindings)
  (let ((bind (assoc e2 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* e1 (cdr bind) nil))))

(defmethod matching-actual-expr* ((e1 name-expr) (e2 extraction-expr)
				  bindings)
  (let ((bind (assoc e1 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* (cdr bind) e2 nil))))

(defmethod matching-actual-expr* ((e1 projection-application)
				  (e2 projection-application)
				  bindings)
  (or (eq e1 e2)
      (with-slots ((id1 index) (arg1 argument)) e1
	(with-slots ((id2 index) (arg2 argument)) e2
	  (and (= id1 id2)
	       (matching-actual-expr* arg1 arg2 bindings))))))

(defmethod matching-actual-expr* ((e1 projection-application) (e2 name-expr)
				  bindings)
  (let ((bind (assoc e2 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* e1 (cdr bind) bindings))))

(defmethod matching-actual-expr* ((e1 name-expr) (e2 projection-application)
				  bindings)
  (let ((bind (assoc e1 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* (cdr bind) e2 bindings))))

(defmethod matching-actual-expr* ((e1 injection-application)
				  (e2 injection-application)
				  bindings)
  (or (eq e1 e2)
      (with-slots ((id1 index) (arg1 argument)) e1
	(with-slots ((id2 index) (arg2 argument)) e2
	  (and (= id1 id2)
	       (matching-actual-expr* arg1 arg2 bindings))))))

(defmethod matching-actual-expr* ((e1 injection-application) (e2 name-expr)
				  bindings)
  (let ((bind (assoc e2 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* e1 (cdr bind) bindings))))

(defmethod matching-actual-expr* ((e1 name-expr) (e2 injection-application)
				  bindings)
  (let ((bind (assoc e1 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* (cdr bind) e2 bindings))))

(defmethod matching-actual-expr* ((e1 injection?-application)
				  (e2 injection?-application)
				  bindings)
  (or (eq e1 e2)
      (with-slots ((id1 index) (arg1 argument)) e1
	(with-slots ((id2 index) (arg2 argument)) e2
	  (and (= id1 id2)
	       (matching-actual-expr* arg1 arg2 bindings))))))

(defmethod matching-actual-expr* ((e1 injection?-application) (e2 name-expr)
				  bindings)
  (let ((bind (assoc e2 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* e1 (cdr bind) bindings))))

(defmethod matching-actual-expr* ((e1 name-expr) (e2 injection?-application)
				  bindings)
  (let ((bind (assoc e1 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* (cdr bind) e2 bindings))))

(defmethod matching-actual-expr* ((e1 extraction-application)
				  (e2 extraction-application)
				  bindings)
  (or (eq e1 e2)
      (with-slots ((id1 index) (arg1 argument)) e1
	(with-slots ((id2 index) (arg2 argument)) e2
	  (and (= id1 id2)
	       (matching-actual-expr* arg1 arg2 bindings))))))

(defmethod matching-actual-expr* ((e1 extraction-application) (e2 name-expr)
				  bindings)
  (let ((bind (assoc e2 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* e1 (cdr bind) bindings))))

(defmethod matching-actual-expr* ((e1 name-expr) (e2 extraction-application)
				  bindings)
  (let ((bind (assoc e1 bindings :test #'tc-eq)))
    (and bind
	 (matching-actual-expr* (cdr bind) e2 bindings))))

(defmethod matching-actual-expr* ((e1 application) (e2 field-application)
				  bindings)
  (with-slots ((op1 operator) (arg1 argument)) e1
    (with-slots ((id2 id) (arg2 argument)) e2
      (and (typep op1 'name-expr)
	   (eq (id op1) id2)
	   (matching-actual-expr* arg1 arg2 bindings)))))

(defmethod matching-actual-expr* ((e1 number-expr) (e2 number-expr) bindings)
  (declare (ignore bindings))
  (with-slots ((n1 number)) e1
    (with-slots ((n2 number)) e2
      (= (the integer n1) (the integer n2)))))

(defmethod matching-actual-expr* ((e1 record-expr) (e2 record-expr) bindings)
  (with-slots ((ass1 assignments)) e1
    (with-slots ((ass2 assignments)) e2
      (matching-actual-expr-fields ass1 ass2 bindings))))

(defun matching-actual-expr-fields (flds1 flds2 bindings)
  (cond ((null flds1) (null flds2))
	((null flds2) nil)
	(t (let ((fld2 (find (car flds1) flds2
			     :test #'(lambda (x y)
				       (same-id (caar (arguments x))
						(caar (arguments y)))))))
	     (and fld2
		  (matching-actual-expr*
		   (expression (car flds1)) (expression fld2) bindings)
		  (matching-actual-expr-fields
		   (cdr flds1) (remove fld2 flds2) bindings))))))

(defmethod matching-actual-expr* ((e1 tuple-expr) (e2 tuple-expr) bindings)
  (with-slots ((ex1 exprs)) e1
    (with-slots ((ex2 exprs)) e2
      (matching-actual-expr* ex1 ex2 bindings))))

(defmethod matching-actual-expr* ((e1 cases-expr) (e2 cases-expr) bindings)
  (with-slots ((expr1 expression) (sel1 selections) (else1 else-part)) e1
    (with-slots ((expr2 expression) (sel2 selections) (else2 else-part)) e2
      (and (matching-actual-expr* expr1 expr2 bindings)
	   (matching-actual-expr-selections sel1 sel2 bindings)
	   (matching-actual-expr* else1 else2 bindings)))))

(defun matching-actual-expr-selections (sel1 sel2 bindings)
  (cond ((null sel1) (null sel2))
	((null sel2) nil)
	(t (let ((s2 (find (constructor (car sel1)) sel2
			   :test #'tc-eq :key #'constructor)))
	     (and s2
		  (matching-actual-expr* (car sel1) s2 bindings)
		  (matching-actual-expr-selections
		   (cdr sel1) (remove s2 sel2) bindings))))))

(defmethod matching-actual-expr* ((s1 selection) (s2 selection) bindings)
  (with-slots ((args1 args) (ex1 expression)) s1
    (with-slots ((args2 args) (ex2 expression)) s2
      (multiple-value-bind (eq? abindings)
	  (bindings-eq args1 args2 bindings)
	(and eq?
	     (matching-actual-expr* ex1 ex2 abindings))))))

(defmethod matching-actual-expr* ((e1 application) (e2 application) bindings)
  (with-slots ((op1 operator) (arg1 argument)) e1
    (with-slots ((op2 operator) (arg2 argument)) e2
      (and (matching-actual-expr-ops op1 op2 bindings)
	   (matching-actual-expr* arg1 arg2 bindings)))))

(defmethod matching-actual-expr-ops ((op1 name-expr) (op2 field-name-expr)
				     bindings)
  (with-slots ((id1 id) (ty1 types)) op1
    (with-slots ((id2 id) (ty2 type)) op2
      (and (eq id1 id2)
	   (some #'(lambda (ty) (tc-eq-with-bindings ty ty2 bindings))
		 ty1)))))

(defmethod matching-actual-expr-ops (op1 op2 bindings)
  (matching-actual-expr* op1 op2 bindings))

(defmethod matching-actual-expr* ((e1 binding-expr) (e2 binding-expr)
				  ibindings)
  (with-slots ((b1 bindings) (ex1 expression)) e1
    (with-slots ((b2 bindings) (ex2 expression)) e2
      (and (same-binding-op? e1 e2)
	   (multiple-value-bind (eq? abindings)
	       (bindings-eq b1 b2 ibindings)
	     (and eq?
		  (matching-actual-expr* ex1 ex2 abindings)))))))

(defmethod matching-actual-expr* ((A coercion) (B coercion) bindings)
  (or (eq A B)
      (matching-actual-expr* (args1 A) (args1 B) bindings)))

(defmethod matching-actual-expr* ((A coercion) (B expr) bindings)
  (matching-actual-expr* (args1 A) B bindings))

(defmethod matching-actual-expr* ((A expr) (B coercion) bindings)
  (matching-actual-expr* A (args1 B) bindings))

(defmethod matching-actual-expr* ((A name-expr) (B coercion) bindings)
  (matching-actual-expr* A (args1 B) bindings))

(defmethod matching-actual-expr* ((e1 update-expr) (e2 update-expr) bindings)
  (with-slots ((ex1 expression) (ass1 assignments)) e1
    (with-slots ((ex2 expression) (ass2 assignments)) e2
      (and (matching-actual-expr* ex1 ex2 bindings)
	   (matching-actual-expr* ass1 ass2 bindings)))))

(defmethod matching-actual-expr* ((a1 assignment) (a2 assignment) bindings)
  (with-slots ((args1 arguments) (ex1 expression)) a1
    (with-slots ((args2 arguments) (ex2 expression)) a2
      (and (matching-actual-expr* args1 args2 bindings)
	   (matching-actual-expr* ex1 ex2 bindings)))))

(defmethod matching-actual-expr* ((n1 binding) (n2 binding) bindings)
  (declare (ignore bindings))
  (eq n1 n2))

(defmethod matching-actual-expr* ((n1 binding) (n2 name) bindings)
  (declare (ignore bindings))
  nil)

(defmethod matching-actual-expr* ((n1 name) (n2 binding) bindings)
  (declare (ignore bindings))
  nil)

(defmethod matching-actual-expr* ((n1 name) (n2 modname) bindings)
  (declare (ignore bindings))
  nil)

(defmethod matching-actual-expr* ((n1 modname) (n2 name) bindings)
  (declare (ignore bindings))
  nil)

(defmethod matching-actual-expr* ((n1 name-expr) (n2 name-expr) bindings)
  (declare (ignore bindings))
  (some #'(lambda (ty1)
	    (some #'(lambda (ty2)
		      (compatible? ty1 ty2))
		  (remove-if #'symbolp (ptypes n2))))
	(remove-if #'symbolp (ptypes n1))))

(defmethod matching-actual-expr* ((n1 name) (n2 name) bindings)
  (with-slots ((res1 resolutions)) n1
    (with-slots ((res2 resolutions)) n2
      (some #'(lambda (r)
		(if (and (actuals (module-instance r))
			 (actuals (module-instance (car res2))))
		    (tc-eq-with-bindings r (car res2) bindings)
		    (same-declaration-res r (car res2))))
	    res1))))

(defmethod same-declaration-res ((r1 resolution) (r2 resolution))
  (with-slots ((d1 declaration)) r1
    (with-slots ((d2 declaration)) r2
      (or (eq d1 d2)
	  (let ((alias (assq d1 (boolean-aliases))))
	    (and alias (eq (cdr alias) d2)))
	  (let ((alias (assq d2 (boolean-aliases))))
	    (and alias (eq d1 (cdr alias))))))))

(defun match-record-arg-decls (name kind args)
  (when (and (eq kind 'expr)
	     (singleton? args)
	     (null (mod-id name))
	     (null (actuals name))
	     (null (library name)))
    (let ((fdecls (mapcan #'(lambda (pty)
			      (let ((sty (find-supertype pty)))
				(when (typep sty 'recordtype)
				  (let ((fdecl (find name (fields sty)
						     :test #'same-id)))
				    (when fdecl
				      (push (cons fdecl sty) *field-records*)
				      (list fdecl))))))
			  (ptypes (car args))))
	  (modinsts (list (theory-name *current-context*))))
      ;;; FIXME - create resolutions here
      (matching-decls* name fdecls modinsts args nil))))

;;; End of matching-actuals code

;;; matching-mappings - mappings is attached to the name, inst is the
;;; theory that we are comparing to.

(defun matching-mappings (mappings inst)
  (let* ((th (get-theory inst))
	 (decls (interpretable-declarations th)))
    (every #'(lambda (m) (matching-mapping m (mappings inst) decls))
	   mappings)))

(defun matching-mapping (map mappings decls)
  (and (member (lhs map) decls :test #'same-id)
       (let ((mmap (find (lhs map) mappings :test #'same-id :key #'lhs)))
	 (or (null mmap)
	     (if (type-value (rhs map))
		 (and (type-value (rhs mmap))
		      (tc-eq (type-value (rhs map)) (type-value (rhs mmap))))
		 (and (not (type-value (rhs mmap)))
		      (some #'(lambda (pty)
				(tc-eq (type (expr (rhs mmap))) pty))
			    (types (expr (rhs map))))))))))

(defun can-use-for-assuming-tcc? (d)
  (or (not *in-checker*)
      (not *top-proofstate*)
      (not (typep (declaration *top-proofstate*) 'assuming-tcc))
      (let ((ass (generating-assumption (declaration *top-proofstate*))))
	(or (not (eq (module d) (module ass)))
	    (not (memq d (memq ass (all-decls (module ass)))))))))

(defun kind-match (kind1 kind2)
  (or (eq kind1 kind2)
      (and (eq kind2 'rewrite)
	   (memq kind1 '(expr formula)))))

(defun matching-decls* (name decls modinsts args result)
  (if (null decls)
      result
      (let ((res (match-decl name (car decls) modinsts args nil)))
	(matching-decls* name (cdr decls) modinsts args
			 (nconc res result)))))

(defun match-decl (name decl modinsts args result)
  (if (null modinsts)
      result
      (let ((res (matching-decl decl (car modinsts) args
				(theory *current-context*))))
	(match-decl name decl (cdr modinsts) args (nconc res result)))))

;;; Returns a resolution or nil, depending on whether the provided decl matches.
;;;   modinst	- is the module instance, represented by a name with the
;;;		  module id and the actual parameters.
;;;   args	- the arguments to the name, if it is an application
;;;		  note that 'foo()' and 'foo' are treated differently.

(defun matching-decl (decl modinst args mod)
  (let ((modinsts (compatible-arguments? decl modinst args mod)))
    (mapcar #'(lambda (mi)
		(let ((type (when (and (field-decl? decl)
				       (not (member decl *bound-variables*)))
			      (assert args)
			      (subst-mod-params
			       (make-field-type decl)
			       mi))))
		  (make-resolution decl mi type))) 
	    modinsts)))

(defun make-field-type (field-decl)
  (assert *field-records*)
  (let ((rectype (cdr (assq field-decl *field-records*))))
    (if (and (dependent? rectype)
	     (some #'(lambda (x)
		       (and (not (eq x field-decl))
			    (occurs-in x field-decl)))
		   (fields rectype)))
	(let* ((db (mk-dep-binding (make-new-variable '|r| rectype) rectype))
	       (ne (make-dep-field-name-expr db rectype))
	       (ftype (field-application-type (id field-decl) rectype ne)))
	  (mk-funtype db ftype))
	(mk-funtype (list rectype) (type field-decl)))))

(defun make-dep-field-name-expr (db rectype)
  (let ((dres (make-resolution db (theory-name *current-context*) rectype)))
    (mk-name-expr (id db) nil nil dres)))

(defmethod compatible-arguments? (decl modinst args mod)
  (declare (type list args))
  (declare (ignore mod))
  (if (null args)
      (list modinst)
      (let* ((stype (find-supertype (type decl)))
	     (dtypes (when (typep stype 'funtype)
		       (if (singleton? args)
			   (list (domain stype))
			   (domain-types stype))))
	     (args (if (and (singleton? dtypes)
			    (not (singleton? args)))
		       (let ((atup (mk-arg-tuple-expr* args)))
			 (setf (types atup)
			       (all-possible-tupletypes args))
			 (list atup))
		       args)))
	(and dtypes
	     (or (length= dtypes args)
		 (and (singleton? args)
		      (some #'(lambda (ty)
				(let ((sty (find-supertype ty)))
				  (and (typep sty 'tupletype)
				       (length= (types sty) dtypes))))
			    (ptypes (car args))))
		 (progn (push (list :arg-length decl)
			      *resolve-error-info*)
			nil))
	     (if (not (fully-instantiated? modinst))
		 (compatible-uninstantiated? decl modinst dtypes args)
		 (let* ((*generate-tccs* 'none)
			(*smp-include-actuals* t)
			(*smp-dont-cache* t)
			(domtypes (subst-mod-params dtypes modinst)))
		   (assert (fully-instantiated? domtypes))
		   ;;(set-type-actuals modinst)
		   (when (compatible-args? decl args domtypes)
		     (list modinst))))))))

(defmethod compatible-arguments? ((decl field-decl) modinst args mod)
  (declare (ignore mod))
  (cond ((null args) (list modinst))
	((memq decl *bound-variables*)
	 (let* ((stype (find-supertype (type decl)))
		(dtypes (when (funtype? stype)
			  (domain-types stype))))
	   (and (funtype? stype)
		(or (length= dtypes args)
		    (and (singleton? args)
			 (some #'(lambda (ty)
				   (let ((sty (find-supertype ty)))
				     (and (tupletype? sty)
					  (length= (types sty) dtypes))))
			       (ptypes (car args)))))
		(when (compatible-args?
		       decl
		       args
		       (mapcar #'(lambda (dt)
				   (let ((*smp-include-actuals* t)
					 (*smp-dont-cache* t))
				     (if (actuals modinst)
					 (subst-mod-params dt modinst)
					 dt)))
			 dtypes))
		  (list modinst)))))
	(t (if (uninstantiated-theory? modinst)
	       (let* ((stype (find-supertype (type decl)))
		      (dtypes (when (funtype? stype)
				(domain-types stype))))
		 (compatible-uninstantiated? decl (copy modinst) dtypes args))
	       (list modinst)))))

(defmethod compatible-arguments? ((decl type-decl) modinst args mod)
  (declare (ignore mod))
  (if (null args)
      (list modinst)
      (let ((fargs (car (formals decl))))
	(and fargs
	     (or (length= fargs args)
		 (and (singleton? args)
		      (some #'(lambda (ty)
				(let ((sty (find-supertype ty)))
				  (and (typep sty 'tupletype)
				       (length= (types sty) fargs))))
			    (ptypes (car args))))
		 (progn (push (list :arg-length decl)
			      *resolve-error-info*)
			nil))
	     (if (not (fully-instantiated? modinst))
		 (compatible-uninstantiated?
		  decl
		  modinst
		  (mapcar #'(lambda (fd) (find-supertype (type fd)))
		    (car (formals decl)))
		  args)
		 (when (compatible-args?
			decl args
			(mapcar #'(lambda (fa)
				    (subst-mod-params (type fa) modinst))
				fargs))
		   (list modinst)))))))

(defun uninstantiated-theory? (modinst)
  (assert *current-theory*)
  (unless (same-id modinst *current-theory*)
    (let ((theory (get-theory modinst)))
      (and (formals theory)
	   (or (null (actuals modinst))
	       (some #'(lambda (a)
			 (let ((d (declaration a)))
			   (and (formal-decl? d)
				(not (member d (formals *current-theory*))))))
		     (actuals modinst)))))))

(defmethod compatible-uninstantiated? (decl modinst dtypes args)
  (let ((bindings (find-compatible-bindings
		   args
		   dtypes
		   (mapcar #'list (formals-sans-usings (module decl))))))
    (or (create-compatible-modinsts modinst bindings nil)
	(progn (push (list :no-instantiation decl)
		     *resolve-error-info*)
	       nil))))

(defmethod compatible-uninstantiated? ((decl type-decl) modinst dtypes args)
  (let ((bindings (find-compatible-bindings
		   args
		   dtypes
		   (mapcar #'list
		     (formals-sans-usings (get-theory modinst))))))
    (create-compatible-modinsts modinst bindings nil)))

(defun create-compatible-modinsts (modinst bindings result)
  (if (null bindings)
      result
      (create-compatible-modinsts
       modinst (cdr bindings)
       (if (every #'cdr (car bindings))
	   (cons (copy modinst
		   'actuals (mapcar #'(lambda (a)
					(mk-res-actual (cdr a) modinst))
			      (car bindings)))
		 result)
	   (cons (copy modinst) result)))))

(defun mk-res-actual (expr modinst)
  (if (member (id modinst) '(|equalities| |notequal|))
      (mk-actual (find-supertype expr))
      (mk-actual expr)))


;;; Compatible-args? checks that there is some assignment of the
;;; possible types of the arguments that is compatible with the
;;; corresponding type provided by the declaration.  In making this
;;; check, the actual parameters will be substituted for the formal
;;; parameters in the declaration.

(defun compatible-args? (decl args types)
  (if (length= args types)
      (compatible-args*? decl args types 1)
      (some #'(lambda (ptype)
		(let ((sty (find-supertype ptype)))
		  (and (tupletype? sty)
		       (length= (types sty) types)
		       (every #'compatible? (types sty) types))))
	    (ptypes (car args)))))

(defun compatible-args*? (decl args types argnum)
  (or (null args)
      (cond ((and (injection-application? (car args))
		  (cotupletype? (find-supertype (car types))))
	     (let ((intype (nth (1- (index (car args)))
				(types (find-supertype (car types))))))
	       (when (and intype
			  (some #'(lambda (ptype)
				    (compatible-args**? ptype intype))
				(ptypes (argument (car args)))))
		 (pushnew (find-supertype (car types)) (types (car args))
			  :test #'tc-eq)
		 t)))
	    ((some #'(lambda (ptype)
		       (compatible-args**? ptype (car types)))
		   (ptypes (car args)))
	     (compatible-args*? decl (cdr args) (cdr types) (1+ argnum)))
	    (t (push (list :arg-mismatch decl argnum args types)
		     *resolve-error-info*)
	       nil))))

(defun compatible-args**? (atype etype)
  (and (compatible? atype etype)
       (or (not (fully-instantiated? atype))
	   (not (fully-instantiated? etype))
	   (not (disjoint-types? atype etype)))))

(defun disallowed-free-variable? (decl)
  (and (typep decl 'var-decl)
       (not (typep (declaration *current-context*) 'formula-decl))))


;;; Filter-preferences returns a subset of the list of decls, filtering
;;; out declarations which are not as preferred as others.  Given
;;; declarations D1 and D2 of types T1 and T2, D1 is prefered to D2 if:
;;;   
;;;   T1 is a subtype of T2, or

(defun filter-preferences (name reses kind args)
  (declare (ignore name))
  (if (cdr reses)
      (let* ((dreses (remove-duplicates reses :test #'tc-eq))
	     (res (or (remove-if
			  #'(lambda (r)
			      (typep (module-instance r) 'datatype-modname))
			dreses)
		      dreses)))
	(if (eq kind 'expr)
	    (if (cdr res)
		(filter-equality-resolutions
		 (filter-nonlocal-module-instances
		  (filter-local-expr-resolutions
		   (filter-bindings res args))))
		res)
	    (remove-mapping-resolutions
	     (remove-outsiders (remove-generics res)))))
      reses))

;;; If both the generic and several (2 or more) instantiated resolutions
;;; are available, throw away the instantiated ones.
(defun filter-nonlocal-module-instances (res &optional freses)
  (if (null res)
      freses
      (multiple-value-bind (mreses rest)
	  (split-on #'(lambda (r) (same-declaration r (car res)))
		    res)
	(filter-nonlocal-module-instances
	 rest (nconc (filter-nonlocal-module-instances* mreses) freses)))))

(defun filter-nonlocal-module-instances* (mreses)
  (if (cddr mreses) ;; at least three - possibly a generic and two others
      (let ((th (module (declaration (car mreses)))))
	(if (or (null th)
		(from-prelude? th)
		(from-prelude-library? th))
	    mreses
	    (multiple-value-bind (freses ureses)
		(split-on #'fully-instantiated? mreses)
	      (if ureses
		  (append ureses
			  (remove-if (complement
				      #'(lambda (r)
					  (member (module-instance r)
						  (get-immediate-usings
						   (current-theory))
						  :test #'tc-eq)))
			    freses))
		  mreses))))
      mreses))

(defun remove-mapping-resolutions (reses)
  (remove-if #'(lambda (res)
		 (and (mappings (module-instance res))
		      (some #'(lambda (r)
				(and (not (mappings (module-instance r)))
				     (eq (declaration r) (declaration res))))
			    reses)))
    reses))

(defun filter-equality-resolutions (reses)
  (if (and (cdr reses)
	   (memq (id (module-instance (car reses)))
		 '(|equalities| |notequal|)))
      (filter-equality-resolutions* reses)
      reses))

(defun filter-equality-resolutions* (reses &optional result)
  (if (null reses)
      (nreverse result)
      (multiple-value-bind (creses nreses)
	  (split-on #'(lambda (res)
			(compatible? (type res) (type (car reses))))
		    reses)
	(filter-equality-resolutions*
	 nreses
	 (if (null creses)
	     (cons (car reses) result)
	     (cons (let ((ctype (reduce #'compatible-type creses :key #'type)))
		     (or (find-if #'(lambda (res) (tc-eq (type res) ctype))
			   creses)
			 (make-resolution (declaration (car reses))
			   (copy (module-instance (car reses))
			     'actuals (list (mk-actual ctype))))))
		   result))))))

(defun remove-smaller-types-of-same-theories (reses &optional result)
  (if (null reses)
      result
      (let* ((modinst (module-instance (car reses)))
	     (amodinst (adt-modinst modinst)))
	(if (and (not (eq amodinst modinst))
		 (or (some #'(lambda (r) (tc-eq (module-instance r) amodinst))
			   (cdr reses))
		     (some #'(lambda (r) (tc-eq (module-instance r) amodinst))
			   result)))
	    (remove-smaller-types-of-same-theories (cdr reses) result)
	    (remove-smaller-types-of-same-theories
	     (cdr reses) (cons (car reses) result))))))

(defun filter-bindings (reses args)
  (or (remove-if-not #'(lambda (r) (memq (declaration r) *bound-variables*))
	reses)
      (and (not *in-checker*)
	   (not *in-evaluator*)
	   (remove-if-not #'(lambda (r) (var-decl? (declaration r))) reses))
      (and args
	   (filter-res-exact-matches reses args))
      reses))

(defun filter-res-exact-matches (reses args)
  (let ((exact-matches
	 (remove-if-not #'(lambda (r)
			    (let* ((stype (find-supertype (type r)))
				   (dtypes (if (cdr args)
					       (domain-types stype)
					       (list (if (dep-binding?
							  (domain stype))
							 (type (domain stype))
							 (domain stype))))))
			      (every #'(lambda (a dt)
					 (some #'(lambda (aty)
						   (or (not (funtype? dt))
						       (tc-eq aty dt)))
					       (types a)))
				     args dtypes)))
	   reses)))
    (append exact-matches
	    (remove-if #'(lambda (r)
			   (or (memq r exact-matches)
			       (let* ((stype (find-supertype (type r))))
				 (some #'(lambda (r2)
					   (compatible? (range stype)
							(range (find-supertype (type r2)))))
				       exact-matches))))
	      reses))))

(defun filter-local-expr-resolutions (reses)
  (if *get-all-resolutions*
      reses
      (filter-local-expr-resolutions* reses nil)))

(defun filter-local-expr-resolutions* (reses freses)
  (if (null reses)
      freses
      (let ((res (car reses)))
	(filter-local-expr-resolutions*
	 (cdr reses)
	 (if (or (member res (cdr reses) :test #'same-type-but-less-local)
		 (member res freses :test #'same-type-but-less-local))
	     freses
	     (cons res freses))))))

(defun same-type-but-less-local (res1 res2)
  (and (tc-eq (type res1) (type res2))
       (< (locality res2) (locality res1))))

(defmethod locality ((ex name-expr))
  (assert (resolution ex))
  (locality (resolution ex)))

(defmethod locality ((res resolution))
  (locality (declaration res)))

(defmethod locality ((decl binding))
  0)

(defmethod locality ((ex lambda-expr))
  ;; This comes from K_conversion
  4)

(defmethod locality ((decl declaration))
  (with-slots (module) decl
    (cond ((eq module (current-theory))
	   1)
	  ((from-prelude? module)
	   4)
	  ((typep module '(or library-theory library-datatype))
	   3)
	  (t 2))))

(defun partition-on-same-ranges (reses partition)
  (if (null reses)
      (mapcar #'cdr partition)
      (let* ((range (range (find-supertype (type (car reses)))))
	     (part (assoc range partition :test #'tc-eq)))
	(cond (part
	       (nconc part (list (car reses)))
	       (partition-on-same-ranges (cdr reses) partition))
	      (t (partition-on-same-ranges
		  (cdr reses)
		  (acons range (list (car reses)) partition)))))))

(defun remove-outsiders (resolutions)
  (filter-local-resolutions resolutions))

(defun remove-indirect-formals (resolutions)
  (or (remove-if-not
       #'(lambda (r)
	   (every #'(lambda (a)
			   (let ((name (or (type-value a)
					   (expr a))))
			     (or (not (name? name))
				 (eq (module (declaration name))
				     (theory *current-context*)))))
		       (actuals (module-instance r))))
       resolutions)
      resolutions))

(defun remove-generics (resolutions)
  (delete-if #'(lambda (r)
		 (and (null (actuals (module-instance r)))
		      (some@ #'(lambda (rr)
				(and (same-id (module-instance r)
					      (module-instance rr))
				     (actuals (module-instance rr))
				     (eq (declaration r)
					 (declaration rr))))
			    resolutions)))
	     resolutions))

(defmethod resolve ((name symbol) kind args &optional
		    (context *current-context*))
  (let* ((n (mk-name-expr name))
	 (res (resolve n kind args context)))
    (when (singleton? res)
      (setf (resolutions n) res)
      n)))

(defmethod resolve ((name name) kind args
		    &optional (context *current-context*))
  (let ((res (resolution name)))
    (if (resolution name)
	(when (eq (kind-of (declaration res)) kind)
	  (list res))
	(let* ((*current-context* context)
	       (nname (if (actuals name)
			  (copy-untyped name)
			  name))
	       (*get-all-resolutions* t))
	  (resolve* nname kind args)))))

(defun formula-or-definition-resolutions (name)
  (let* ((*resolve-error-info* nil)
	 (reses (append (resolve name 'formula nil)
			(resolve name 'expr nil))))
    (or reses
	(resolution-error name 'expr-or-formula nil nil))))

(defun definition-resolutions (name)
  (let* ((*resolve-error-info* nil)
	 (reses (remove-if-not #'(lambda (r)
				   (and (const-decl? (declaration r))
					(definition (declaration r))))
		  (resolve name 'expr nil))))
    (or reses
	(resolution-error name 'expr nil nil))))

(defun formula-resolutions (name)
  (let* ((*resolve-error-info* nil)
	 (reses (resolve name 'formula nil)))
    (or reses
	(resolution-error name 'formula nil nil))))
	  

;;; resolve-theory-name is called by the prover.  It returns a list of
;;; instances of the specified theory that are visible in the current
;;; context.
;;;   IF generic input
;;;   THEN IF the generic was imported,
;;;        THEN return it as a singleton list
;;;        ELSE return list of instances
;;;   ELSE IF the instance was imported
;;;        THEN return it as a singleton
;;;        ELSE IF the generic was imported,
;;;             THEN check the actuals, and return the singleton instance
;;;             ELSE return nil

(defun resolve-theory-name (modname)
  (if (eq (id modname) (id (theory *current-context*)))
      (if (actuals modname)
	  (type-error modname "May not instantiate the current theory")
	  modname)
      (if (get-theory modname)
	  (progn
	    (typecheck* modname nil nil nil)
	    (let* ((importings (gethash (get-theory modname)
					(using-hash *current-context*))))
	      (unless importings
		(type-error modname
		  "Theory ~a is not imported in the current context"
		  (id modname)))
	      (when (and (actuals modname)
			 (not (member modname importings :test #'tc-eq))
			 (not (find-if #'(lambda (mi) (null (actuals mi)))
				importings)))
		(type-error modname
		  "Theory instance ~a is not imported in the current context"
		  modname)))
	    modname)
	  (resolve-theory-abbreviation modname))))

(defun resolve-theory-abbreviation (theory-name)
  (let* ((abbrs (remove-if-not #'mod-decl?
		  (gethash (id theory-name) (current-declarations-hash)))))
    (cond ((null abbrs)
	   (type-error theory-name
	     "Theory ~a is not an abbreviation, nor is it imported ~
              in the current context"
	     (id theory-name)))
	  ((singleton? abbrs)
	   (if (fully-instantiated? (modname (car abbrs)))
	       (modname (car abbrs))
	       (break "resolve-theory-abbreviation not fully-instantiated")))
	  (t (break "resolve-theory-abbreviation too many abbreviations")))))
    

(defmethod imported-theory-abbreviation (decl)
  (declare (ignore decl))
  nil)

(defmethod imported-theory-abbreviation ((decl mod-decl))
  (visible? decl))


(defun argument-conversion (name arguments)
  (let ((*found-one* nil)
	(reses (remove-if-not #'(lambda (r)
				  (typep (find-supertype (type r)) 'funtype))
		 (resolve name 'expr nil)))
	)
    (declare (special *found-one*))
    (if (let ((*ignored-conversions*
	       (cons "K_conversion" *ignored-conversions*)))
	  (argument-conversions (mapcar #'type reses) arguments))
	(resolve name 'expr arguments)
	(unless (member "K_conversion" *ignored-conversions* :test #'string=)
	  (let ((*only-use-conversions* (list "K_conversion")))
	    (when (argument-conversions (mapcar #'type reses) arguments)
	      (resolve name 'expr arguments)))))))

(defun argument-conversions (optypes arguments)
  (declare (special *found-one*))
  (if optypes
      (let* ((rtype (find-supertype (car optypes)))
	     (dtypes (when (typep rtype 'funtype)
		       (domain-types rtype)))
	     (dtypes-list (all-possible-instantiations dtypes arguments)))
	(when (length= arguments dtypes)
	  (argument-conversions* arguments dtypes-list))
	(argument-conversions (cdr optypes) arguments))
      *found-one*))

(defun argument-conversions* (arguments dtypes-list &optional aconversions)
  (declare (special *found-one*))
  (if (null dtypes-list)
      aconversions
      (let ((conversions (argument-conversions1 arguments (car dtypes-list)))
	    (found-one nil))
	(when conversions
	  (mapc #'(lambda (arg convs)
		    (when convs
		      (setq found-one t)
		      (setq *found-one* t)
		      (setf (types arg)
			    (remove-duplicates
				(append (types arg)
					(mapcar #'(lambda (c)
						    (get-conversion-range-type
						     c arg))
					  convs))
			      :test #'tc-eq :from-end t))))
		arguments conversions))
	(argument-conversions* arguments (cdr dtypes-list)
			       (if found-one
				   (cons conversions aconversions)
				   aconversions)))))

(defun argument-conversions1 (arguments dtypes &optional result)
  (if (null arguments)
      (unless (every #'null result)
	(nreverse result))
      (let* ((atypes (types (car arguments)))
	     (convs (unless (some #'(lambda (aty)
				      (or (tc-eq aty (car dtypes))
					  (and (compatible? aty (car dtypes))
					       (fully-instantiated?
						(car dtypes)))))
				  atypes)
		      (argument-conversions** atypes (car dtypes)))))
	(argument-conversions1 (cdr arguments) (cdr dtypes)
			       (cons convs result)))))

(defun argument-conversions** (atypes etype &optional result)
  (if (null atypes)
      (nreverse result)
      (let ((conv (find-conversions-for (car atypes) etype)))
	(argument-conversions** (cdr atypes) etype
				(append conv result)))))

(defun all-possible-instantiations (dtypes arguments)
  (when (length= dtypes arguments)
    (if (free-params dtypes)
	(let* ((bindings (instantiate-operator-bindings (free-params dtypes)))
	       (bindings-list (all-possible-bindings dtypes arguments bindings)))
	  (or (all-possible-instantiations* dtypes bindings-list)
	      (list dtypes)))
	(list dtypes))))

(defun all-possible-instantiations* (dtypes bindings-list &optional result)
  (cond ((null bindings-list)
	 (nreverse result))
	(t (assert (every #'cdr (car bindings-list)))
	   (let ((dtypes-inst (instantiate-operator-from-bindings
			       dtypes (car bindings-list))))
	     (all-possible-instantiations* dtypes (cdr bindings-list)
					   (pushnew dtypes-inst result
						    :test #'tc-eq))))))
      

(defun all-possible-bindings (dtypes arguments bindings)
  (cond ((every #'cdr bindings)
	 (list bindings))
	((null dtypes)
	 nil)
	(t (let ((abindings (all-possible-bindings*
			     (car dtypes) (types (car arguments)) bindings)))
	     (delete-duplicates
	      (mapcan #'(lambda (bnd)
			  (all-possible-bindings
			   (cdr dtypes) (cdr arguments) bnd))
		(if (member bindings abindings :test #'equal)
		    abindings
		    (nconc abindings (list bindings))))
	      :test #'equal)))))

(defun all-possible-bindings* (dtype atypes bindings)
  (if (free-params dtype)
      (possible-bindings dtype atypes bindings)
      (list bindings)))

(defun possible-bindings (dtype atypes bindings &optional bindings-list)
  (if (null atypes)
      (nreverse bindings-list)
      (let* ((nbindings (tc-match (car atypes) dtype (copy-tree bindings))))
	(possible-bindings dtype (cdr atypes) bindings
			   (if (and nbindings
				    (not (member nbindings bindings-list
						 :test #'equal)))
			       (cons nbindings bindings-list)
			       bindings-list)))))


;;; This is called by typecheck* (name) when the resolution is nil.  If there
;;; are arguments, it first checks whether there is a conversion available that
;;; would turn the given name into a function of the right type.  If not, then
;;; it looks for a k-conversion so that it can push the conversion down on the
;;; arguments.

(defun function-conversion (name arguments)
  (append (simple-function-conversion name arguments)
	  (resolutions-with-argument-conversions
	   (resolve (copy name 'resolutions nil) 'expr nil) arguments)))

(defun resolutions-with-argument-conversions (resolutions arguments
							  &optional result)
  (if (null resolutions)
      result
      (let* ((rtype (find-supertype (type (car resolutions))))
	     (compats (compatible-arg-conversions? rtype arguments)))
	(resolutions-with-argument-conversions
	 (cdr resolutions)
	 arguments
	 (if (and compats
		  (some #'(lambda (x) (not (eq x 't))) compats))
	     (cons (make-function-conversion-resolution
		    (car resolutions) arguments compats)
		   result)
	     result)))))

(defun make-function-conversion-resolution (res args compats)
  (declare (ignore args))
  (let ((theories (delete *current-theory*
			  (delete-duplicates (mapcar #'module
						     (free-params res)))))
	(dtypes (domain-types (type res)))
	(nres res))
    (dolist (th theories)
      (mapc #'(lambda (dt compat)
		(when (typep compat 'name-expr)
		  (let ((bindings (tc-match
				   (domain (type compat)) dt
				   (mapcar #'(lambda (x)
					       (cons x nil))
				     (formals-sans-usings th)))))
		    (when (and bindings (every #'cdr bindings))
		      (setq nres
			    (subst-mod-params
			     nres
			     (mk-modname (id th)
			       (mapcar #'(lambda (a)
					   (mk-res-actual (cdr a) th))
				 bindings))))))))
	    dtypes compats))
    (change-class nres 'lambda-conversion-resolution)
    (setf (conversion nres) compats)
    (let* ((ktype (type (find-if #'name-expr? compats)))
	   (ftype (mk-funtype (domain ktype)
			      (mk-funtype (domain (range ktype))
					  (range (type nres))))))
      (setf (type nres) ftype))
    nres))

(defun compatible-arg-conversions? (rtype arguments)
  (and (typep rtype 'funtype)
       (let* ((dtypes (domain-types rtype))
	      (dtypes-list (all-possible-instantiations dtypes arguments)))
	 (and (length= dtypes arguments)
	      (let* ((compats (mapcan #'(lambda (dty)
					  (compatible-arguments-k-conversions
					   dty arguments))
				dtypes-list))
		     (k-convtype (get-k-conversion-type compats)))
		(when k-convtype
		  (let* ((ndtypes-list
			  (mapcar #'(lambda (dtypes)
				      (mapcar #'(lambda (dty)
						  (if (and (funtype? dty)
							   (tc-eq k-convtype
								  (domain dty)))
						      (range dty)
						      dty))
					dtypes))
			    dtypes-list))
			 (ncompats (mapcan #'(lambda (dty)
					       (compatible-arguments-k-conversions
						dty arguments))
				     ndtypes-list)))
		    (or ncompats compats))))))))

(defun get-k-conversion-type (compats &optional type)
  (if (null compats)
      type
      (if (eq (car compats) t)
	  (get-k-conversion-type (cdr compats) type)
	  (let ((k-type (domain (range (type (car compats))))))
	    (when (or (null type)
		      (tc-eq type k-type))
	      (get-k-conversion-type (cdr compats) k-type))))))

(defun compatible-arguments-k-conversions (dtypes arguments
						  &optional kconv result)
  (if (null dtypes)
      (nreverse result)
      (let ((conv (compatible-argument-k-conversions
		   (car dtypes) (car arguments))))
	(when conv
	  (assert (or (eq conv t)
		      (name-expr? conv)))
	  (when (or (null kconv)
		    (eq conv t)
		    ;; Do they have the same introduced type, e.g., state?
		    (tc-eq (cadr (actuals (module-instance kconv)))
			   (cadr (actuals (module-instance conv)))))
	    (compatible-arguments-k-conversions
	     (cdr dtypes) (cdr arguments)
	     (or kconv (and (name-expr? conv) conv))
	     (cons conv result)))))))

(defun compatible-argument-k-conversions (dtype argument)
  (or (some #'(lambda (pty)
		(compatible? dtype pty))
	    (ptypes argument))
      (compatible-argument-k-conversion dtype (ptypes argument))))

(defun compatible-argument-k-conversion (dtype ptypes)
  (when ptypes
    (let ((fty (find-supertype (car ptypes))))
      (or (and (typep fty 'funtype)
	       (compatible? (range fty) dtype)
	       (car (get-k-conversions fty)))
	  (compatible-argument-k-conversion dtype (cdr ptypes))))))

(defun k-conversion-resolutions (res kcs arguments &optional result)
  (if (null res)
      result
      (let ((nres (k-conversion-resolutions1 (car res) kcs arguments)))
	(k-conversion-resolutions (cdr res) kcs arguments
				(if nres (cons nres result) result)))))

(defun k-conversion-resolutions1 (res kcs arguments)
  (let ((rtype (find-supertype (type res))))
    (when (and (typep rtype 'funtype)
	       (length= (domain-types rtype) arguments))
      (let ((kc (find-if #'(lambda (kc)
			     (compatible-k-args kc (domain-types rtype) arguments))
		  kcs)))
	(when kc
	  (let ((sres (instantiate-resolution-from-k
		       res (domain (find-supertype (type kc))))))
	    (change-class sres 'conversion-resolution)
	  (setf (conversion sres) kc)
	  sres))))))

(defun instantiate-resolution-from-k (res domain)
  (if (fully-instantiated? (type res))
      res
      (let ((bindings (tc-match domain (domain (find-supertype (type res)))
				(mapcar #'(lambda (x) (cons x nil))
					(formals-sans-usings
					 (get-theory
					  (module-instance res)))))))
	(if (every #'cdr bindings)
	    (subst-mod-params res
			      (car (create-compatible-modinsts
				    (module-instance res)
				    (list bindings)
				    nil)))
	    res))))

(defun compatible-k-args (kc dtypes args)
  (let ((lt (car (domain-types (type kc))))
	(rt (range (type kc))))
    (compatible-k-args* lt rt dtypes args)))

(defun compatible-k-args* (lt rt dtypes args)
  (or (null dtypes)
      (and (some #'(lambda (pty)
		     (or (compatible? pty (car dtypes))
			 (and (compatible? pty rt)
			      (compatible? lt (car dtypes)))))
		 (ptypes (car args)))
	   (compatible-k-args* lt rt (cdr dtypes) (cdr args)))))

(defun matching-k-conversions (args &optional result)
  (if (null args)
      (remove-duplicates result :test #'tc-eq)
      (matching-k-conversions
       (cdr args)
       (append (matching-k-conversions1 (ptypes (car args)))
	       result))))

(defun matching-k-conversions1 (atypes &optional result)
  (if (null atypes)
      result
      (matching-k-conversions1
       (cdr atypes)
       (append (get-k-conversions (car atypes)) result))))

(defun simple-function-conversion (name arguments)
  (let ((reses (resolve name 'expr nil))
	(creses nil))
    (mapc #'(lambda (r)
	      (let ((conv (car (get-resolution-conversions r arguments))))
		(when conv
		  (assert (typep conv 'name-expr))
		  (push (make-conversion-resolution r conv name)
			creses))))
	  reses)
    creses))

(defun get-resolution-conversions (res arguments)
  (get-resolution-conversions*
   (remove-if #'k-combinator? (conversions *current-context*))
   res arguments nil))

(defun get-resolution-conversions* (conversions res arguments result)
  (if (null conversions)
      (nreverse result)
      (let ((conv (compatible-resolution-conversion (car conversions)
						    res arguments)))
	(get-resolution-conversions* (cdr conversions) res arguments
				     (if conv
					 (cons conv result)
					 result)))))

(defun compatible-resolution-conversion (conversion res arguments)
  (let ((nconv (compatible-operator-conversion conversion (type res) arguments)))
    (when nconv (name nconv))))

(defun compatible-resolution-conversion-args (bindings ctype arguments)
  (let* ((cran (find-supertype (range ctype)))
	 (dtypes (when (typep cran 'funtype)
		   (domain-types cran)))
	 (bindings-list (find-compatible-bindings arguments dtypes bindings)))
    (car bindings-list)))

(defun compatible-resolution-conversion? (ctype res arguments)
  (and (compatible? (domain ctype) (type res))
       (or (null arguments)
	   (let ((cran (find-supertype (range ctype))))
	     (and (typep cran 'funtype)
		  (let* ((dtypes (domain-types cran))
			 (args (if (and (singleton? dtypes)
					(not (singleton? arguments)))
				   (list (typecheck* (mk-arg-tuple-expr*
						      arguments)
						     nil nil nil))
				   arguments)))
		    (and (length= dtypes args)
			 (every #'(lambda (a dty)
				    (some #'(lambda (pty)
					      (compatible? pty dty))
					  (ptypes a)))
				args dtypes))))))))

(defun make-conversion-resolution (res conv name)
  (let* ((ctype (find-supertype (type conv)))
	 (dep? (typep (domain ctype) 'dep-binding))
	 (nname (when dep?
		  (copy name
		    'type (type res)
		    'resolutions (list res))))
	 (rtype (if dep?
		    (substit (range ctype)
		      (acons (domain ctype) nname nil))
		    (range ctype)))
	 (cconv (copy conv)))
    (change-name-expr-class-if-needed (declaration conv) cconv)
    (make-instance 'conversion-resolution
      'module-instance (module-instance res)
      'declaration (declaration res)
      'type (copy rtype 'from-conversion cconv)
      'conversion cconv)))

(defun get-conversion-range-type (conv expr)
  (let* ((ctype (find-supertype (type conv)))
	 (dep? (typep (domain ctype) 'dep-binding))
	 (nexpr (when dep?
		  (typecheck* (copy-untyped expr) (domain ctype) nil nil)))
	 (rtype (if dep?
		    (substit (range ctype)
		      (acons (domain ctype) nexpr nil))
		    (range ctype)))
	 (cconv (copy conv)))
    (when (name-expr? conv)
      (change-name-expr-class-if-needed (declaration conv) cconv))
    (copy rtype 'from-conversion cconv)))


;;; Resolution error handling

(defun resolution-error (name kind arguments &optional (type-error? t))
  (let ((reses (when (actuals name)
		 (mapcan #'(lambda (k)
			     (resolve (copy name 'actuals nil) k arguments))
		   (if (eq kind 'expr-or-formula)
		       '(expr formula)
		       (list kind))))))
    (multiple-value-bind (obj error)
	(if (and *resolve-error-info*
		 (or (assq :arg-mismatch *resolve-error-info*)
		     (not (assq :no-instantiation *resolve-error-info*))))
	    (resolution-args-error *resolve-error-info* name arguments)
	    (values
	     name
	     (format nil
		 "~v%Expecting a~a~%No resolution for ~a~
                  ~@[ with arguments of possible types: ~:{~%  ~<~a~3i : ~{~_ ~a~^,~}~>~}~]~
                  ~@[~% Check the actual parameters; the following ~
                        instances are visible,~% but don't match the ~
                        given actuals:~%   ~{~a~^, ~}~]
                  ~:[~;~% There is a variable declaration with this name,~% ~
                          but free variables are not allowed here.~]"
	       (if *in-checker* 1 0)
	       (if *typechecking-actual*
		   "n expression or type"
		   (case kind
		     (expr "n expression")
		     (type " type")
		     (formula " formula")
		     (expr-or-formula " formula or constant")
		     (expr-or-type "n expression or type")
		     (t (format nil " ~a" kind))))
	       name
	       (mapcar #'(lambda (a) (list a (full-name (ptypes a) 1)))
		 arguments)
	       (mapcar #'(lambda (r)
			   (mk-name (id (declaration r))
			     (actuals (module-instance r))
			     (id (module-instance r))))
		 reses)
	       (some #'var-decl?
		     (gethash (id name) (current-declarations-hash))))
	     name))
      (if (and (eq kind 'expr)
	       (conversion-occurs-in? arguments))
	  (let* ((appl (mk-application* name arguments))
		 (*type-error*
		  (format nil
		      "--------------~%With conversions, it becomes the ~
                     expression ~%  ~a~%and leads to the error:~%  ~a"
		    appl error))
		 (*no-conversions-allowed* t))
	    (untypecheck-theory appl)
	    (typecheck appl))
	  (progn
	    (when (check-if-k-conversion-would-work name arguments)
	      (setq error
		    (format nil
			"~a~%Enabling K_conversion before this declaration might help"
		      error)))
	  (if type-error?
	      (type-error-noconv obj error)
	      (progn (set-strategy-errors error)
		     nil)))))))

(defun resolution-args-error (infolist name arguments)
  (let ((info (car (best-guess-resolution-error infolist arguments))))
    (case (car info)
      (:arg-length
       (values name
	       (format nil
		   "Wrong number of arguments:~%  ~d provided, ~d expected"
		 (length arguments)
		 (length (if (typep (cadr info) 'expr)
			     (domain-types (type (cadr info)))
			     (car (formals (cadr info))))))))
      (:arg-mismatch
       ;; Info = (:arg-mismatch decl argnum args types)
       (values (car (fourth info))
	       (format nil
		   "~:r argument to ~a has the wrong type~
                    ~%     Found: ~{~a~%~^~12T~}  Expected: ~a"
		 (third info)
		 name
		 (mapcar #'(lambda (fn) (unpindent fn 12 :string t))
		   (full-name (ptypes (car (fourth info))) 1))
		 (full-name (car (fifth info)) 1)))))))

(defun best-guess-resolution-error (infolist arguments)
  (if (cdr infolist)
      (let ((mismatches (remove-if-not
			    #'(lambda (x) (eq (car x) :arg-mismatch))
			  infolist)))
	(if mismatches
	    (best-guess-mismatch-error mismatches arguments)
	    (best-guess-length-error infolist arguments)))
      infolist))

(defun best-guess-mismatch-error (infolist arguments &optional best bnum)
  (if (null infolist)
      best
      (let ((num (number-of-compatible-args (fifth (car infolist))
					    (fourth (car infolist))
					    (1- (third (car infolist))))))
	(best-guess-mismatch-error
	 (cdr infolist)
	 arguments
	 (cond ((or (null best)
		    (> num bnum))
		(list (car infolist)))
	       ((= num bnum)
		(cons (car infolist) best))
	       (t best))
	 (if (or (null bnum)
		 (> num bnum))
	     num
	     bnum)))))

(defun number-of-compatible-args (types args &optional (num 0))
  (if (null args)
      num
      (number-of-compatible-args
       (cdr types)
       (cdr args)
       (if (some #'(lambda (ptype)
		    (compatible-args**? ptype (car types)))
		(ptypes (car args)))
	   (1+ num)
	   num))))

(defun best-guess-length-error (infolist arguments)
  (declare (ignore arguments))
  infolist)
