#lang racket

(require racket/class
  racket/contract)

(provide Prog-Base)

(define Prog-Base%
(class object%
(super-new)

(init-field strand snap)

(define/public (initialize strand [snap #f])
(set! snap (or snap (SemSnap-new (send strand id))))
(set! strand strand)
(set! subject-id (or (send this frame "subject_id") (send strand id))))

(define/public (subject-is . names)
(for-each
(λ (name)
  (eval
   `(define (,name)
      (or (hash-ref ,(symbol->string (camelize (symbol->string name))) subject-id)
          (set! ,name (hash-ref ,(symbol->string (camelize (symbol->string name))) subject-id))))))
names))

(define/public (semaphore . names)
(for-each
(λ (name)
  (define (incr-name) (send snap incr name))
  (define (decr-name) (send snap decr name))
  (define (when-name-set? proc)
    (when (send snap set? (symbol->string name))
      (proc))))
(map symbol->string names)))

(define/public (labels)
(or labels '()))

(define/public (label label)
(set! labels (cons label labels))
(define (hop-label) (send this dynamic-hop label)))

(define/public (nap [seconds 30])
(error 'Nap (seconds)))

(define/public (pop . args)
(define outval
 (match args
   [(list str) `("msg" ,str)]
   [(list (hash? h)) h]
   [else (error "BUG: must pop with string or hash")]))

(if (> (length (send strand stack)) 0)
   (let ((link (hash-ref (send this frame) "link" #f)))
     (when link
       (let* ((pg (Page-from-tag-parts "Deadline" (send strand id) (send strand prog) (hash-ref (car (send strand stack)) "deadline_target" #f))))
              (old-prog (send strand prog))
              (old-label (send strand label))
              (prog (car link))
              (label (cdr link)))
         (when pg (send pg incr-resolve))
         (error 'Hop (old-prog old-label `((retval ,outval)
                                           (stack ,(send strand stack))
                                           (prog ,prog)
                                           (label ,label)))))))
   (error "BUG: expect no stacks exceeding depth 1 with no back-link")))

(define/public (frame)
(hash-ref (send strand stack) 0 #f))

(define/public (retval)
(send strand retval))

(define/public (push prog [new-frame #f] [label "start"])
(let* ((old-prog (send strand prog))
      (old-label (send strand label))
      (new-frame (hash-set* (or new-frame (make-hash))
                            "subject_id" subject-id
                            "link" (list (send strand prog) old-label))))
 (error 'Hop old-prog old-label `((prog ,(Strand-prog-verify prog))
                                  (label ,label)
                                  (stack ,(cons new-frame (send strand stack)))
                                  (retval ,#f)))))

(define/public (bud prog [new-frame #f] [label "start"])
(let ((new-frame (hash-set* (or new-frame (make-hash)) "subject_id" subject-id)))
 (send strand add-child
       (list "id" (Strand-generate-uuid)
             "prog" (Strand-prog-verify prog)
             "label" label
             "stack" (vector new-frame)))))

(define/public (donate)
(for-each (lambda (child) (send child run)) (send strand children))
(send this nap 1))

(define/public (reap)
(let ((reapable (filter (lambda (child)
                         (let ((lease (hash-ref child 'lease #f))
                               (exitval (hash-ref child 'exitval #f)))
                           (or (not lease) (< lease (current-seconds)) exitval)))
                       (send strand children-dataset))))
 (for-each
  (lambda (child)
    (Semaphore-where "strand_id" (hash-ref child 'id) #:destroy #t)
    (send child destroy))
  reapable)
 reapable))

(define/public (leaf?)
(empty? (send strand children)))

(define/public (register-deadline deadline-target deadline-in #:allow-extension [allow-extension #f])
(let ((current-frame (hash-ref (send strand stack) 0 #f)))
 (let* ((deadline-at (hash-ref current-frame "deadline_at" #f))
        (old-deadline-target (hash-ref current-frame "deadline_target" #f))
        (deadline-now (+ (current-seconds) deadline-in)))
   (when (or (not deadline-at)
             (not (equal? old-deadline-target deadline-target))
             allow-extension
             (> deadline-at deadline-now))
     (when (and (not (equal? old-deadline-target deadline-target))
                (Page-from-tag-parts "Deadline" (send strand id) (send strand prog) old-deadline-target))
       (send (Page-from-tag-parts "Deadline" (send strand id) (send strand prog) old-deadline-target) incr-resolve))
     (hash-set! current-frame "deadline_target" deadline-target)
     (hash-set! current-frame "deadline_at" deadline-now)
     (send strand modified! 'stack)))))

(define/private (dynamic-hop label)
(unless (symbol? label)
 (error "BUG: #hop only accepts a symbol"))
(unless (member label (labels))
 (error "BUG: not valid hop target"))
(let ((label-str (symbol->string label)))
 (error 'Hop (send strand prog) (send strand label) `((label ,label-str)
                                                      (retval ,#f)))))

(define/private (camelize s)
(regexp-replace* #rx"/(.)"
                (regexp-replace* #rx"(_|^)(.)" s
                                 (λ (m) (string-upcase (substring m 1))))
                (λ (m) (string-append "::" (string-upcase (substring m 1))))))

(define subject-id (send this frame "subject_id"))))

(define (Prog-Base-new strand [snap #f])
(send (new Prog-Base%) initialize strand snap))
