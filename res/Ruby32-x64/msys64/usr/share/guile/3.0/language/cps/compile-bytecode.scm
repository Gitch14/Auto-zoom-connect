;;; Continuation-passing style (CPS) intermediate language (IL)

;; Copyright (C) 2013-2021 Free Software Foundation, Inc.

;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;;
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;;
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

;;; Commentary:
;;;
;;; Compiling CPS to bytecode.  The result is in the bytecode language,
;;; which happens to be an ELF image as a bytecode.
;;;
;;; Code:

(define-module (language cps compile-bytecode)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (language cps)
  #:use-module (language cps slot-allocation)
  #:use-module (language cps utils)
  #:use-module (language cps intmap)
  #:use-module (language cps intset)
  #:use-module (system vm assembler)
  #:use-module (system base types internal)
  #:export (compile-bytecode))

(define (kw-arg-ref args kw default)
  (match (memq kw args)
    ((_ val . _) val)
    (_ default)))

(define (intmap-for-each f map)
  (intmap-fold (lambda (k v seed) (f k v) seed) map *unspecified*))

(define (intmap-select map set)
  (persistent-intmap
   (intset-fold
    (lambda (k out)
      (intmap-add! out k (intmap-ref map k)))
    set
    empty-intmap)))

;; Any $values expression that continues to a $kargs and causes no
;; shuffles is a forwarding label.  $kreceive conts also forward to
;; their continuations.
(define (compute-forwarding-labels cps allocation)
  (fixpoint
   (lambda (forwarding-map)
     (intmap-fold (lambda (label target forwarding-map)
                    (let ((new-target (intmap-ref forwarding-map target
                                                  (lambda (target) target))))
                      (if (eqv? target new-target)
                          forwarding-map
                          (intmap-replace forwarding-map label new-target))))
                  forwarding-map forwarding-map))
   (intmap-fold (lambda (label cont forwarding-labels)
                  (match cont
                    (($ $kargs _ _ ($ $continue k _ ($ $values)))
                     (match (lookup-send-parallel-moves label allocation)
                       (()
                        (match (intmap-ref cps k)
                          (($ $ktail) forwarding-labels)
                          (_ (intmap-add forwarding-labels label k))))
                       (_ forwarding-labels)))
                    (($ $kreceive arity kargs)
                     (intmap-add forwarding-labels label kargs))
                    (_ forwarding-labels)))
                cps empty-intmap)))

(define (compile-function cps asm opts)
  (let* ((allocation (allocate-slots cps #:precolor-calls?
                                     (kw-arg-ref opts #:precolor-calls? #t)))
         (forwarding-labels (compute-forwarding-labels cps allocation))
         (frame-size (lookup-nlocals allocation)))
    (define (forward-label k)
      (intmap-ref forwarding-labels k (lambda (k) k)))

    (define (elide-cont? label)
      (match (intmap-ref forwarding-labels label (lambda (_) #f))
        (#f #f)
        (target (not (eqv? label target)))))

    (define (maybe-slot sym)
      (lookup-maybe-slot sym allocation))

    (define (slot sym)
      (lookup-slot sym allocation))

    (define (from-sp var)
      (- frame-size 1 var))

    (define (maybe-mov dst src)
      (unless (= dst src)
        (emit-mov asm (from-sp dst) (from-sp src))))

    (define (emit-moves moves)
      (for-each (match-lambda
                  ((src . dst)
                   (emit-mov asm (from-sp dst) (from-sp src))))
                moves))

    (define (compile-tail nlocals emit-tail)
      (unless (= frame-size nlocals)
        (emit-reset-frame asm nlocals))
      (emit-handle-interrupts asm)
      (emit-tail asm))

    (define (compile-receive label proc-slot cont)
      (define (shuffle-results)
        (let lp ((moves (lookup-receive-parallel-moves label allocation))
                 (reset-frame? #f))
          (cond
           ((and (not reset-frame?)
                 (and-map (match-lambda
                            ((src . dst)
                             (and (< src frame-size) (< dst frame-size))))
                          moves))
            (emit-reset-frame asm frame-size)
            (emit-moves moves))
           (else
            (match moves
              (() #t)
              (((src . dst) . moves)
               (emit-fmov asm dst src)
               (lp moves reset-frame?)))))))
      (match cont
        (($ $kargs)
         (shuffle-results))
        (($ $kreceive ($ $arity req () rest () #f) kargs)
         (let ((nreq (length req))
               (rest-var (and rest
                              (match (intmap-ref cps kargs)
                                (($ $kargs names (_ ... rest))
                                 rest)))))
           (cond
            ((and (= 1 nreq) rest-var (not (maybe-slot rest-var))
                  (match (lookup-receive-parallel-moves label allocation)
                    ((((? (lambda (src) (= src proc-slot)) src)
                       . dst)) dst)
                    (_ #f)))
             ;; A common case: one required live return value,
             ;; ignoring any additional values.
             => (lambda (dst)
                  (emit-receive asm dst proc-slot frame-size)))
            (else
             (unless (and (zero? nreq) rest-var)
               (emit-receive-values asm proc-slot (->bool rest-var) nreq))
             (when (and rest-var (maybe-slot rest-var))
               (emit-bind-rest asm (+ proc-slot nreq)))
             (shuffle-results)))))))

    (define (compile-value exp dst)
      (match exp
        (($ $primcall (or 's64->u64 'u64->s64) #f (arg))
         (maybe-mov dst (slot arg)))
        (($ $const exp)
         (emit-load-constant asm (from-sp dst) exp))
        (($ $const-fun k)
         (emit-load-static-procedure asm (from-sp dst) k))
        (($ $code k)
         (emit-load-label asm (from-sp dst) k))
        (($ $primcall 'current-module)
         (emit-current-module asm (from-sp dst)))
        (($ $primcall 'current-thread)
         (emit-current-thread asm (from-sp dst)))
        (($ $primcall 'define! #f (mod sym))
         (emit-define! asm (from-sp dst)
                       (from-sp (slot mod)) (from-sp (slot sym))))
        (($ $primcall 'resolve (bound?) (name))
         (emit-resolve asm (from-sp dst) bound? (from-sp (slot name))))
        (($ $primcall 'allocate-words annotation (nfields))
         (emit-allocate-words asm (from-sp dst) (from-sp (slot nfields))))
        (($ $primcall 'allocate-words/immediate (annotation . nfields))
         (emit-allocate-words/immediate asm (from-sp dst) nfields))
        (($ $primcall 'allocate-pointerless-words annotation (nfields))
         (emit-allocate-pointerless-words asm (from-sp dst)
                                       (from-sp (slot nfields))))
        (($ $primcall 'allocate-pointerless-words/immediate
            (annotation . nfields))
         (emit-allocate-pointerless-words/immediate asm (from-sp dst) nfields))
        (($ $primcall 'scm-ref annotation (obj idx))
         (emit-scm-ref asm (from-sp dst) (from-sp (slot obj))
                       (from-sp (slot idx))))
        (($ $primcall 'scm-ref/tag annotation (obj))
         (let ((tag (match annotation
                      ('pair %tc1-pair)
                      ('struct %tc3-struct))))
           (emit-scm-ref/tag asm (from-sp dst) (from-sp (slot obj)) tag)))
        (($ $primcall 'scm-ref/immediate (annotation . idx) (obj))
         (emit-scm-ref/immediate asm (from-sp dst) (from-sp (slot obj)) idx))
        (($ $primcall 'word-ref annotation (obj idx))
         (emit-word-ref asm (from-sp dst) (from-sp (slot obj))
                       (from-sp (slot idx))))
        (($ $primcall 'word-ref/immediate (annotation . idx) (obj))
         (emit-word-ref/immediate asm (from-sp dst) (from-sp (slot obj)) idx))
        (($ $primcall 'pointer-ref/immediate (annotation . idx) (obj))
         (emit-pointer-ref/immediate asm (from-sp dst) (from-sp (slot obj)) idx))
        (($ $primcall 'tail-pointer-ref/immediate (annotation . idx) (obj))
         (emit-tail-pointer-ref/immediate asm (from-sp dst) (from-sp (slot obj))
                                          idx))
        (($ $primcall 'cache-ref key ())
         (emit-cache-ref asm (from-sp dst) key))
        (($ $primcall 'resolve-module public? (name))
         (emit-resolve-module asm (from-sp dst) (from-sp (slot name)) public?))
        (($ $primcall 'module-variable #f (mod name))
         (emit-module-variable asm (from-sp dst) (from-sp (slot mod))
                               (from-sp (slot name))))
        (($ $primcall 'lookup #f (mod name))
         (emit-lookup asm (from-sp dst) (from-sp (slot mod))
                      (from-sp (slot name))))
        (($ $primcall 'lookup-bound #f (mod name))
         (emit-lookup-bound asm (from-sp dst) (from-sp (slot mod))
                            (from-sp (slot name))))
        (($ $primcall 'lookup-bound-public (mod name) ())
         (let ((name (symbol->string name)))
           (emit-lookup-bound-public asm (from-sp dst) mod name)))
        (($ $primcall 'lookup-bound-private (mod name) ())
         (let ((name (symbol->string name)))
           (emit-lookup-bound-private asm (from-sp dst) mod name)))
        (($ $primcall 'add/immediate y (x))
         (emit-add/immediate asm (from-sp dst) (from-sp (slot x)) y))
        (($ $primcall 'sub/immediate y (x))
         (emit-sub/immediate asm (from-sp dst) (from-sp (slot x)) y))
        (($ $primcall 'uadd/immediate y (x))
         (emit-uadd/immediate asm (from-sp dst) (from-sp (slot x)) y))
        (($ $primcall 'usub/immediate y (x))
         (emit-usub/immediate asm (from-sp dst) (from-sp (slot x)) y))
        (($ $primcall 'umul/immediate y (x))
         (emit-umul/immediate asm (from-sp dst) (from-sp (slot x)) y))
        (($ $primcall 'rsh (x y))
         (emit-rsh asm (from-sp dst) (from-sp (slot x)) (from-sp (slot y))))
        (($ $primcall 'lsh (x y))
         (emit-lsh asm (from-sp dst) (from-sp (slot x)) (from-sp (slot y))))
        (($ $primcall 'rsh/immediate y (x))
         (emit-rsh/immediate asm (from-sp dst) (from-sp (slot x)) y))
        (($ $primcall 'lsh/immediate y (x))
         (emit-lsh/immediate asm (from-sp dst) (from-sp (slot x)) y))
        (($ $primcall 'ursh/immediate y (x))
         (emit-ursh/immediate asm (from-sp dst) (from-sp (slot x)) y))
        (($ $primcall 'srsh/immediate y (x))
         (emit-srsh/immediate asm (from-sp dst) (from-sp (slot x)) y))
        (($ $primcall 'ulsh/immediate y (x))
         (emit-ulsh/immediate asm (from-sp dst) (from-sp (slot x)) y))
        (($ $primcall 'builtin-ref idx ())
         (emit-builtin-ref asm (from-sp dst) idx))
        (($ $primcall 'scm->f64 #f (src))
         (emit-scm->f64 asm (from-sp dst) (from-sp (slot src))))
        (($ $primcall 'load-f64 val ())
         (emit-load-f64 asm (from-sp dst) val))
        (($ $primcall 'scm->u64 #f (src))
         (emit-scm->u64 asm (from-sp dst) (from-sp (slot src))))
        (($ $primcall 'scm->u64/truncate #f (src))
         (emit-scm->u64/truncate asm (from-sp dst) (from-sp (slot src))))
        (($ $primcall 'load-u64 val ())
         (emit-load-u64 asm (from-sp dst) val))
        (($ $primcall 'u64->scm #f (src))
         (emit-u64->scm asm (from-sp dst) (from-sp (slot src))))
        (($ $primcall 'scm->s64 #f (src))
         (emit-scm->s64 asm (from-sp dst) (from-sp (slot src))))
        (($ $primcall 'load-s64 val ())
         (emit-load-s64 asm (from-sp dst) val))
        (($ $primcall 's64->scm #f (src))
         (emit-s64->scm asm (from-sp dst) (from-sp (slot src))))

        (($ $primcall 'u8-ref ann (obj ptr idx))
         (emit-u8-ref asm (from-sp dst) (from-sp (slot ptr))
                      (from-sp (slot idx))))
        (($ $primcall 's8-ref ann (obj ptr idx))
         (emit-s8-ref asm (from-sp dst) (from-sp (slot ptr))
                      (from-sp (slot idx))))
        (($ $primcall 'u16-ref ann (obj ptr idx))
         (emit-u16-ref asm (from-sp dst) (from-sp (slot ptr))
                       (from-sp (slot idx))))
        (($ $primcall 's16-ref ann (obj ptr idx))
         (emit-s16-ref asm (from-sp dst) (from-sp (slot ptr))
                       (from-sp (slot idx))))
        (($ $primcall 'u32-ref ann (obj ptr idx))
         (emit-u32-ref asm (from-sp dst) (from-sp (slot ptr))
                       (from-sp (slot idx))))
        (($ $primcall 's32-ref ann (obj ptr idx))
         (emit-s32-ref asm (from-sp dst) (from-sp (slot ptr))
                       (from-sp (slot idx))))
        (($ $primcall 'u64-ref ann (obj ptr idx))
         (emit-u64-ref asm (from-sp dst) (from-sp (slot ptr))
                       (from-sp (slot idx))))
        (($ $primcall 's64-ref ann (obj ptr idx))
         (emit-s64-ref asm (from-sp dst) (from-sp (slot ptr))
                       (from-sp (slot idx))))
        (($ $primcall 'f32-ref ann (obj ptr idx))
         (emit-f32-ref asm (from-sp dst) (from-sp (slot ptr))
                       (from-sp (slot idx))))
        (($ $primcall 'f64-ref ann (obj ptr idx))
         (emit-f64-ref asm (from-sp dst) (from-sp (slot ptr))
                       (from-sp (slot idx))))

        (($ $primcall 'atomic-scm-ref/immediate (annotation . idx) (obj))
         (emit-atomic-scm-ref/immediate asm (from-sp dst) (from-sp (slot obj))
                                        idx))
        (($ $primcall 'atomic-scm-swap!/immediate (annotation . idx) (obj val))
         (emit-atomic-scm-swap!/immediate asm (from-sp dst) (from-sp (slot obj))
                                          idx (from-sp (slot val))))
        (($ $primcall 'atomic-scm-compare-and-swap!/immediate (annotation . idx)
            (obj expected desired))
         (emit-atomic-scm-compare-and-swap!/immediate
          asm (from-sp dst) (from-sp (slot obj)) idx (from-sp (slot expected))
          (from-sp (slot desired))))

        (($ $primcall 'untag-fixnum #f (src))
         (emit-untag-fixnum asm (from-sp dst) (from-sp (slot src))))
        (($ $primcall 'tag-fixnum #f (src))
         (emit-tag-fixnum asm (from-sp dst) (from-sp (slot src))))
        (($ $primcall 'untag-char #f (src))
         (emit-untag-char asm (from-sp dst) (from-sp (slot src))))
        (($ $primcall 'tag-char #f (src))
         (emit-tag-char asm (from-sp dst) (from-sp (slot src))))
        (($ $primcall name #f args)
         ;; FIXME: Inline all the cases.
         (emit-text asm `((,name ,(from-sp dst)
                                 ,@(map (compose from-sp slot) args)))))))

    (define (compile-effect exp)
      (match exp
        (($ $primcall 'cache-set! key (val))
         (emit-cache-set! asm key (from-sp (slot val))))
        (($ $primcall 'scm-set! annotation (obj idx val))
         (emit-scm-set! asm (from-sp (slot obj)) (from-sp (slot idx))
                        (from-sp (slot val))))
        (($ $primcall 'scm-set!/tag annotation (obj val))
         (let ((tag (match annotation
                      ('pair %tc1-pair)
                      ('struct %tc3-struct))))
           (emit-scm-set!/tag asm (from-sp (slot obj)) tag
                              (from-sp (slot val)))))
        (($ $primcall 'scm-set!/immediate (annotation . idx) (obj val))
         (emit-scm-set!/immediate asm (from-sp (slot obj)) idx
                                  (from-sp (slot val))))
        (($ $primcall 'word-set! annotation (obj idx val))
         (emit-word-set! asm (from-sp (slot obj)) (from-sp (slot idx))
                        (from-sp (slot val))))
        (($ $primcall 'word-set!/immediate (annotation . idx) (obj val))
         (emit-word-set!/immediate asm (from-sp (slot obj)) idx
                                   (from-sp (slot val))))
        (($ $primcall 'pointer-set!/immediate (annotation . idx) (obj val))
         (emit-pointer-set!/immediate asm (from-sp (slot obj)) idx
                                      (from-sp (slot val))))
        (($ $primcall 'string-set! #f (string index char))
         (emit-string-set! asm (from-sp (slot string)) (from-sp (slot index))
                           (from-sp (slot char))))
        (($ $primcall 'push-fluid #f (fluid val))
         (emit-push-fluid asm (from-sp (slot fluid)) (from-sp (slot val))))
        (($ $primcall 'pop-fluid #f ())
         (emit-pop-fluid asm))
        (($ $primcall 'push-dynamic-state #f (state))
         (emit-push-dynamic-state asm (from-sp (slot state))))
        (($ $primcall 'pop-dynamic-state #f ())
         (emit-pop-dynamic-state asm))
        (($ $primcall 'wind #f (winder unwinder))
         (emit-wind asm (from-sp (slot winder)) (from-sp (slot unwinder))))

        (($ $primcall 'u8-set! ann (obj ptr idx val))
         (emit-u8-set! asm (from-sp (slot ptr)) (from-sp (slot idx))
                       (from-sp (slot val))))
        (($ $primcall 's8-set! ann (obj ptr idx val))
         (emit-s8-set! asm (from-sp (slot ptr)) (from-sp (slot idx))
                       (from-sp (slot val))))
        (($ $primcall 'u16-set! ann (obj ptr idx val))
         (emit-u16-set! asm (from-sp (slot ptr)) (from-sp (slot idx))
                        (from-sp (slot val))))
        (($ $primcall 's16-set! ann (obj ptr idx val))
         (emit-s16-set! asm (from-sp (slot ptr)) (from-sp (slot idx))
                        (from-sp (slot val))))
        (($ $primcall 'u32-set! ann (obj ptr idx val))
         (emit-u32-set! asm (from-sp (slot ptr)) (from-sp (slot idx))
                        (from-sp (slot val))))
        (($ $primcall 's32-set! ann (obj ptr idx val))
         (emit-s32-set! asm (from-sp (slot ptr)) (from-sp (slot idx))
                        (from-sp (slot val))))
        (($ $primcall 'u64-set! ann (obj ptr idx val))
         (emit-u64-set! asm (from-sp (slot ptr)) (from-sp (slot idx))
                        (from-sp (slot val))))
        (($ $primcall 's64-set! ann (obj ptr idx val))
         (emit-s64-set! asm (from-sp (slot ptr)) (from-sp (slot idx))
                        (from-sp (slot val))))
        (($ $primcall 'f32-set! ann (obj ptr idx val))
         (emit-f32-set! asm (from-sp (slot ptr)) (from-sp (slot idx))
                        (from-sp (slot val))))
        (($ $primcall 'f64-set! ann (obj ptr idx val))
         (emit-f64-set! asm (from-sp (slot ptr)) (from-sp (slot idx))
                        (from-sp (slot val))))

        (($ $primcall 'unwind #f ())
         (emit-unwind asm))
        (($ $primcall 'fluid-set! #f (fluid value))
         (emit-fluid-set! asm (from-sp (slot fluid)) (from-sp (slot value))))
        (($ $primcall 'atomic-scm-set!/immediate (annotation . idx) (obj val))
         (emit-atomic-scm-set!/immediate asm (from-sp (slot obj)) idx
                                         (from-sp (slot val))))
        (($ $primcall 'instrument-loop #f ())
         (emit-instrument-loop asm)
         (emit-handle-interrupts asm))))

    (define (compile-throw op param args)
      (match (vector op param args)
        (#('throw #f (key args))
         (emit-throw asm (from-sp (slot key)) (from-sp (slot args))))
        (#('throw/value param (val))
         (emit-throw/value asm (from-sp (slot val)) param))
        (#('throw/value+data param (val))
         (emit-throw/value+data asm (from-sp (slot val)) param))))

    (define (compile-prompt label k kh escape? tag)
      (let ((receive-args (gensym "handler"))
            (proc-slot (lookup-call-proc-slot label allocation)))
        (emit-prompt asm (from-sp (slot tag)) escape? proc-slot
                     receive-args)
        (emit-j asm k)
        (emit-label asm receive-args)
        (compile-receive label proc-slot (intmap-ref cps kh))
        (emit-j asm (forward-label kh))))

    (define (compile-test label next-label kf kt op param args)
      (define (prefer-true?)
        (if (< (max kt kf) label)
            ;; Two backwards branches.  Prefer
            ;; the nearest.
            (> kt kf)
            ;; Otherwise prefer a backwards
            ;; branch or a near jump.
            (< kt kf)))
      (define (emit-branch emit-jt emit-jf)
        (cond
         ((eq? kt next-label)
          (emit-jf asm kf))
         ((eq? kf next-label)
          (emit-jt asm kt))
         ((prefer-true?)
          (emit-jt asm kt)
          (emit-j asm kf))
         (else
          (emit-jf asm kf)
          (emit-j asm kt))))
      (define (unary op a)
        (op asm (from-sp (slot a)))
        (emit-branch emit-je emit-jne))
      (define (binary op emit-jt emit-jf a b)
        (op asm (from-sp (slot a)) (from-sp (slot b)))
        (emit-branch emit-jt emit-jf))
      (define (binary-test op a b)
        (binary op emit-je emit-jne a b))
      (define (binary-< emit-<? a b)
        (binary emit-<? emit-jl emit-jnl a b))
      (define (binary-<= emit-<? a b)
        (binary emit-<? emit-jge emit-jnge b a))
      (define (binary-test/imm op a b)
        (op asm (from-sp (slot a)) b)
        (emit-branch emit-je emit-jne))
      (define (binary-</imm op a b)
        (op asm (from-sp (slot a)) b)
        (emit-branch emit-jl emit-jnl))
      (match (vector op param args)
        ;; Immediate type tag predicates.
        (#('fixnum? #f (a)) (unary emit-fixnum? a))
        (#('heap-object? #f (a)) (unary emit-heap-object? a))
        (#('char? #f (a)) (unary emit-char? a))
        (#('eq-constant? imm (a)) (binary-test/imm emit-eq-immediate? a imm))
        (#('undefined? #f (a)) (unary emit-undefined? a))
        (#('null? #f (a)) (unary emit-null? a))
        (#('false? #f (a)) (unary emit-false? a))
        (#('nil? #f (a)) (unary emit-nil? a))
        ;; Heap type tag predicates.
        (#('pair? #f (a)) (unary emit-pair? a))
        (#('struct? #f (a)) (unary emit-struct? a))
        (#('symbol? #f (a)) (unary emit-symbol? a))
        (#('variable? #f (a)) (unary emit-variable? a))
        (#('vector? #f (a)) (unary emit-vector? a))
        (#('mutable-vector? #f (a)) (unary emit-mutable-vector? a))
        (#('immutable-vector? #f (a)) (unary emit-immutable-vector? a))
        (#('string? #f (a)) (unary emit-string? a))
        (#('heap-number? #f (a)) (unary emit-heap-number? a))
        (#('hash-table? #f (a)) (unary emit-hash-table? a))
        (#('pointer? #f (a)) (unary emit-pointer? a))
        (#('fluid? #f (a)) (unary emit-fluid? a))
        (#('stringbuf? #f (a)) (unary emit-stringbuf? a))
        (#('dynamic-state? #f (a)) (unary emit-dynamic-state? a))
        (#('frame? #f (a)) (unary emit-frame? a))
        (#('keyword? #f (a)) (unary emit-keyword? a))
        (#('atomic-box? #f (a)) (unary emit-atomic-box? a))
        (#('syntax? #f (a)) (unary emit-syntax? a))
        (#('program? #f (a)) (unary emit-program? a))
        (#('vm-continuation? #f (a)) (unary emit-vm-continuation? a))
        (#('bytevector? #f (a)) (unary emit-bytevector? a))
        (#('weak-set? #f (a)) (unary emit-weak-set? a))
        (#('weak-table? #f (a)) (unary emit-weak-table? a))
        (#('array? #f (a)) (unary emit-array? a))
        (#('bitvector? #f (a)) (unary emit-bitvector? a))
        (#('smob? #f (a)) (unary emit-smob? a))
        (#('port? #f (a)) (unary emit-port? a))
        (#('bignum? #f (a)) (unary emit-bignum? a))
        (#('flonum? #f (a)) (unary emit-flonum? a))
        (#('compnum? #f (a)) (unary emit-compnum? a))
        (#('fracnum? #f (a)) (unary emit-fracnum? a))
        ;; Binary predicates.
        (#('eq? #f (a b)) (binary-test emit-eq? a b))
        (#('heap-numbers-equal? #f (a b))
         (binary-test emit-heap-numbers-equal? a b))
        (#('< #f (a b)) (binary-< emit-<? a b))
        (#('<= #f (a b)) (binary-<= emit-<? a b))
        (#('= #f (a b)) (binary-test emit-=? a b))
        (#('u64-< #f (a b)) (binary-< emit-u64<? a b))
        (#('u64-imm-< b (a)) (binary-</imm emit-u64-imm<? a b))
        (#('imm-u64-< b (a)) (binary-</imm emit-imm-u64<? a b))
        (#('u64-= #f (a b)) (binary-test emit-u64=? a b))
        (#('u64-imm-= b (a)) (binary-test/imm emit-s64-imm=? a b))
        (#('s64-= #f (a b)) (binary-test emit-u64=? a b))
        (#('s64-imm-= b (a)) (binary-test/imm emit-s64-imm=? a b))
        (#('s64-< #f (a b)) (binary-< emit-s64<? a b))
        (#('s64-imm-< b (a)) (binary-</imm emit-s64-imm<? a b))
        (#('imm-s64-< b (a)) (binary-</imm emit-imm-s64<? a b))
        (#('f64-< #f (a b)) (binary-< emit-f64<? a b))
        (#('f64-<= #f (a b)) (binary-<= emit-f64<? a b))
        (#('f64-= #f (a b)) (binary-test emit-f64=? a b))))

    (define (skip-elided-conts label)
      (if (elide-cont? label)
          (skip-elided-conts (1+ label))
          label))

    (define (compile-expression label k exp)
      (let* ((forwarded-k (forward-label k))
             (fallthrough? (= forwarded-k (skip-elided-conts (1+ label))))
             (cont (intmap-ref cps k)))
        (define (maybe-emit-jump)
          (unless fallthrough?
            (emit-j asm forwarded-k)))
        (define (compile-values nvalues)
          (emit-moves (lookup-send-parallel-moves label allocation))
          (match cont
            (($ $ktail)
             (compile-tail nvalues emit-return-values))
            (($ $kargs)
             (maybe-emit-jump))))
        (define (compile-call kfun proc args)
          (emit-moves (lookup-send-parallel-moves label allocation))
          (let* ((nclosure (if proc 1 0))
                 (nargs (+ nclosure (length args))))
            (match cont
              (($ $ktail)
               (compile-tail nargs
                             (if kfun
                                 (lambda (asm)
                                   (emit-tail-call-label asm kfun))
                                 emit-tail-call)))
              (_
               (let ((proc-slot (lookup-call-proc-slot label allocation)))
                 (emit-handle-interrupts asm)
                 (if kfun
                     (emit-call-label asm proc-slot nargs kfun)
                     (emit-call asm proc-slot nargs))
                 (emit-slot-map asm proc-slot
                                (lookup-slot-map label allocation))
                 (compile-receive label proc-slot cont)
                 (maybe-emit-jump))))))
        (match exp
          (($ $values args)
           (compile-values (length args)))
          (($ $call proc args)
           (compile-call #f proc args))
          (($ $callk kfun proc args)
           (compile-call kfun proc args))
          (_
           (match cont
             (($ $kargs names vars)
              (match vars
                (() (compile-effect exp))
                ((var)
                 (let ((dst (maybe-slot var)))
                   (when dst
                     (compile-value exp dst)))))
              (maybe-emit-jump)))))))

    (define (compile-term label term)
      (match term
        (($ $continue k src exp)
         (when src
           (emit-source asm src))
         (unless (elide-cont? label)
           (compile-expression label k exp)))
        (($ $branch kf kt src op param args)
         (when src
           (emit-source asm src))
         (compile-test label (skip-elided-conts (1+ label))
                       (forward-label kf) (forward-label kt)
                       op param args))
        (($ $switch kf kt* src arg)
         (when src
           (emit-source asm src))
         (emit-jtable asm (from-sp (slot arg))
                      (list->vector (map forward-label
                                         (append kt* (list kf))))))
        (($ $prompt k kh src escape? tag)
         (when src
           (emit-source asm src))
         (compile-prompt label (skip-elided-conts k) kh escape? tag))
        (($ $throw src op param args)
         (when src
           (emit-source asm src))
         (compile-throw op param args))))

    (define (compile-cont label cont)
      (match cont
        (($ $kfun src meta self tail entry)
         (when src
           (emit-source asm src))
         (emit-begin-program asm label meta)
         (match (intmap-ref cps entry)
           (($ $kclause)
            ;; Leave arity handling to the dispatcher.
            #t)
           (($ $kargs names vars _)
            ;; Otherwise the $kfun continues to the $kargs directly,
            ;; without any arity checking, so we begin the arity here.
            (emit-begin-unchecked-arity asm (->bool self) names frame-size)
            (when self
              (emit-definition asm 'closure 0 'scm)))))
        (($ $kclause ($ $arity req opt rest kw allow-other-keys?) body alt)
         (let ((first? (match (intmap-ref cps (1- label))
                         (($ $kfun) #t)
                         (_ #f)))
               (has-closure? (match (intmap-ref cps (intmap-next cps))
                               (($ $kfun src meta self tail) (->bool self))))
               (kw-indices (map (match-lambda
                                 ((key name sym)
                                  (cons key (lookup-slot sym allocation))))
                                kw)))
           (unless first?
             (emit-end-arity asm))
           (emit-label asm label)
           (emit-begin-kw-arity asm has-closure? req opt rest kw-indices
                                allow-other-keys? frame-size alt)
           (when has-closure?
             ;; Most arities define a closure binding in slot 0.
             (emit-definition asm 'closure 0 'scm))
           ;; Usually we just fall through, but it could be the body is
           ;; contified into another clause.
           (let ((body (forward-label body)))
             (unless (= body (skip-elided-conts (1+ label)))
               (emit-j asm body)))))
        (($ $kargs names vars term)
         (emit-label asm label)
         (for-each (lambda (name var)
                     (let ((slot (maybe-slot var)))
                       (when slot
                         (let ((repr (lookup-representation var allocation)))
                           (emit-definition asm name slot repr)))))
                   names vars)
         (compile-term label term))
        (($ $kreceive arity kargs)
         (emit-label asm label))
        (($ $ktail)
         (emit-end-arity asm)
         (emit-end-program asm))))

    (intmap-for-each compile-cont cps)))

(define (compile-bytecode exp env opts)
  (let ((asm (make-assembler)))
    (intmap-for-each (lambda (kfun body)
                       (compile-function (intmap-select exp body) asm opts))
                     (compute-reachable-functions exp 0))
    (values (link-assembly asm #:page-aligned? (kw-arg-ref opts #:to-file? #f))
            env
            env)))