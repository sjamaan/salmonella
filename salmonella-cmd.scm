(use salmonella salmonella-log-parser)
(include "salmonella-common.scm")

(define default-verbosity 2)

(define (progress-indicator action egg verbosity #!optional egg-count total)
  (case verbosity
    ((0) "")
    ((1) (when (eq? action 'fetch) (print "=== " egg)))
    (else
     (let ((running (case action
                      ((fetch) (print "==== " egg " (" egg-count " of " total ")====")
                       "  Fetching")
                      ((install) "  Installing")
                      ((check-version) "  Checking version")
                      ((test) "  Testing")
                      ((meta-data) "  Reading .meta")
                      ((check-dependencies) "  Checking dependencies")
                      ((check-category) "  Checking category")
                      ((doc) "  Checking documentation")
                      (else (error 'salmonella-progress-indicator
                                   "Invalid action"
                                   action)))))
       (display (string-pad-right running 50 #\.))
       (flush-output)))))


(define (status-reporter report verbosity)
  (case verbosity
    ((0 1) "")
    (else
     (let ((status (report-status report))
           (action (report-action report)))
       (print
        (case status
          ((0 #t) "[ ok ]")
          ((-1) "[ -- ]")
          (else "[fail]"))
        " "
        (if (or (eq? action 'check-version)
                (and (eq? action 'test)
                     (= status -1)))
            ""
            (conc (report-duration report) "s")))))))


(define (show-statistics log-file verbosity)
  (when (> verbosity 1)
    (let ((log (read-log-file log-file)))
      (print #<#EOF

***************************************************************************

=== Summary
Total eggs: #(count-total-eggs log)

==== Installation
Ok: #(count-install-ok log)
Failed: #(count-install-fail log)

==== Tests
Ok: #(count-test-ok log)
Failed: #(count-test-fail log)
No tests: #(count-no-test log)

==== Documentation
Documented: #(count-documented log)
Undocumented: #(count-undocumented log)

==== Total run time
#(prettify-time (inexact->exact (total-time log)))
EOF
))))


(define (usage #!optional exit-code)
  (let ((this (pathname-strip-directory (program-name))))
    (display #<#EOF
#this [ -h | --help ]
#this <options> eggs

<options>:
--log-file=<logfile>  (default=salmonella.log)
--chicken-installation-prefix=<prefix dir>
--chicken-install-args=<install args>
--eggs-source-dir=<eggs dir>
--eggs-doc-dir=<doc dir>
--keep-repo
--skip-eggs=<comma-separated list of eggs to skip>
--this-egg
--repo-dir=<path to repo dir to be used>
--verbosity=<number>
EOF
)
    (newline)
    (when exit-code (exit exit-code))))

(let* ((args (command-line-arguments))
       (log-file (or (cmd-line-arg '--log-file args) "salmonella.log"))
       (chicken-installation-prefix
        (cmd-line-arg '--chicken-installation-prefix args))
       (chicken-install-args
        (cmd-line-arg '--chicken-install-args args))
       (eggs-source-dir
        (cmd-line-arg '--eggs-source-dir args))
       (eggs-doc-dir
        (cmd-line-arg '--eggs-doc-dir args))
       (skip-eggs (let ((skip (cmd-line-arg '--skip-eggs args)))
                    (if skip
                        (map string->symbol (string-split skip ","))
                        '())))
       (keep-repo? (and (member "--keep-repo" args) #t))
       (this-egg? (and (member "--this-egg" args) #t))
       (repo-dir (and-let* ((path (cmd-line-arg '--repo-dir args)))
                   (if (absolute-pathname? path)
                       path
                       (normalize-pathname
                        (make-pathname (current-directory) path)))))
       (tmp-dir (or repo-dir (mktempdir)))
       (verbosity (or (and-let* ((verbosity (cmd-line-arg '--verbosity args)))
                        (or (string->number verbosity) default-verbosity))
                      default-verbosity))
       (salmonella (make-salmonella
                    tmp-dir
                    eggs-source-dir: eggs-source-dir
                    eggs-doc-dir: eggs-doc-dir
                    chicken-installation-prefix: chicken-installation-prefix
                    chicken-install-args:
                      (and chicken-install-args
                           (lambda (repo)
                             (or (irregex-replace "<repo>" chicken-install-args repo)
                                 chicken-install-args)))
                    this-egg?: this-egg?))
       (eggs (if this-egg?
                 (let ((setup (glob "*.setup")))
                   (cond ((null? setup)
                          (die "Could not find a .setup file. Aborting."))
                         ((null? (cdr setup))
                          (map (compose string->symbol pathname-file) setup))
                         (else
                          (die "Found more than one .setup file.  Aborting."))))
                 (remove (lambda (egg)
                           (memq egg skip-eggs))
                         (map string->symbol
                              (remove (lambda (arg)
                                        (string-prefix? "--" arg))
                                      args)))))
       (total-eggs (length eggs)))

  (when (or (member "-h" args)
            (member "--help" args))
    (usage 0))

  (when (null? eggs)
    (print "Nothing to do.")
    (exit))

  ;; Remove the temporary directory if interrupted
  (set-signal-handler! signal/int
                       (lambda (signal)
                         (delete-path tmp-dir)
                         (exit)))

  (when (> verbosity 1)
    (print "Using " tmp-dir " as temporary directory"))

  ;; Remove old log
  (delete-file* log-file)

  ;; Log start
  (log! (make-report #f 'start 0 (salmonella 'env-info) (current-seconds))
        log-file)

  (for-each
   (lambda (egg egg-count)

     (unless keep-repo? (salmonella 'clear-repo!))

     (salmonella 'init-repo!)

     ;; Fetch egg
     (progress-indicator 'fetch egg verbosity egg-count total-eggs)
     (let ((fetch-log (salmonella 'fetch egg)))
       (log! fetch-log log-file)
       (status-reporter fetch-log verbosity)

       (when (zero? (report-status fetch-log))

         ;; Meta data
         (progress-indicator 'meta-data egg verbosity)
         (let ((meta-log (salmonella 'meta-data egg)))
           (log! meta-log log-file)
           (status-reporter meta-log verbosity)

           (when (report-status meta-log)
             (let ((meta-data (report-message meta-log)))

               ;; Warnings (only logged when indicate problems)

               ;; Check dependencies
               (progress-indicator 'check-dependencies egg verbosity)
               (let ((deps-log (salmonella 'check-dependencies egg meta-data)))
                 (unless (report-status deps-log)
                   (log! deps-log log-file))
                 (status-reporter deps-log verbosity))

               ;; Check category
               (progress-indicator 'check-category egg verbosity)
               (let ((categ-log (salmonella 'check-category egg meta-data)))
                 (unless (report-status categ-log)
                   (log! categ-log log-file))
                 (status-reporter categ-log verbosity))


               ;; Install egg
               (progress-indicator 'install egg verbosity)
               (let ((install-log (salmonella 'install egg)))
                 (log! install-log log-file)
                 (status-reporter install-log verbosity)

                 (when (zero? (report-status install-log))
                   ;; Check version
                   (let ((check-version-log (salmonella 'check-version egg)))
                     (unless (= -1 (report-status check-version-log))
                       (progress-indicator 'check-version egg verbosity)
                       (log! check-version-log log-file)
                       (status-reporter check-version-log verbosity)))

                   ;; Test egg
                   (progress-indicator 'test egg verbosity)
                   (let ((test-log (salmonella 'test egg)))
                     (log! test-log log-file)
                     (status-reporter test-log verbosity)))))))))

     ;; Check doc
     (progress-indicator 'doc egg verbosity)
     (let ((doc-log (salmonella 'doc egg)))
       (log! doc-log log-file)
       (status-reporter doc-log verbosity)))

   eggs
   (iota total-eggs 1))

  (log! (make-report #f 'end 0 "" (current-seconds)) log-file)
  (show-statistics log-file verbosity)
  (unless keep-repo? (delete-path tmp-dir)))
