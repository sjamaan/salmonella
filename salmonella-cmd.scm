(use srfi-1 regex)
(load "salmonella")
(load "salmonella-log-parser")

(define (cmd-line-arg option args)
  ;; Returns the argument associated to the command line option OPTION
  ;; in ARGS or #f if OPTION is not found in ARGS or doesn't have any
  ;; argument.
  (let ((val (any (cut string-match (conc option "=(.*)") <>) args)))
    (and val (cadr val))))


(define (progress-indicator action egg)
  (let ((running (case action
                   ((fetch) (print "==== " egg " ====") "  Fetching")
                   ((install) "  Installing")
                   ((check-version) "  Checking version")
                   ((test) "  Testing")
                   ((meta-check) "  Checking .meta")
                   (else (error 'salmonella-progress-indicator
                                "Invalid action"
                                action)))))
    (display (string-pad-right running 50 #\.))
    (flush-output)))


(define (status-reporter report)
  (let ((status (report-status report))
        (action (report-action report)))
    (print
     (case status
       ((0) "[ ok ]")
       ((-1) "[ -- ]")
       (else "[fail]"))
     " "
     (if (or (eq? action 'check-version)
             (and (eq? action 'test)
                  (= status -1)))
         ""
         (conc (report-duration report) "s")))))


(define (show-statistics log-file)
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
EOF
)))


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
--keep-repo
--skip-eggs=<comma-separated list of eggs to skip>
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
       (skip-eggs (let ((skip (cmd-line-arg '--skip-eggs args)))
                    (if skip
                        (map string->symbol (string-split skip ","))
                        '())))
       (keep-repo? (and (member "--keep-repo" args) #t))
       (tmp-dir (create-temporary-directory))
       (salmonella (make-salmonella
                    tmp-dir
                    eggs-source-dir: eggs-source-dir
                    chicken-installation-prefix: chicken-installation-prefix
                    chicken-install-args: (and chicken-install-args
                                               (lambda (repo)
                                                 (string-substitute*
                                                  chicken-install-args
                                                  `(("<repo>" . ,repo)))))))
       (eggs (remove (lambda (egg)
                       (memq egg skip-eggs))
                     (map string->symbol
                          (remove (lambda (arg)
                                    (string-prefix? "--" arg))
                                  args)))))

  (when (or (member "-h" args)
            (member "--help" args))
    (usage 0))

  (when (null? eggs)
    (print "Nothing to do.")
    (exit))

  ;; Remove the temporary directory if interrupted
  (set-signal-handler! signal/int
                       (lambda ()
                         (delete-path tmp-dir)
                         (exit)))


  (print "Using " tmp-dir " as temporary directory")

  ;; Remove old log
  (delete-file* log-file)

  ;; Log start
  (log! (make-report #f 'start 0 (salmonella 'env-info) (current-seconds))
        log-file)

  (for-each
   (lambda (egg)

     (unless keep-repo? (salmonella 'clear-repo!))

     (salmonella 'init-repo!)

     ;; Fetch egg
     (progress-indicator 'fetch egg)
     (let ((fetch-log (salmonella 'fetch egg)))
       (log! fetch-log log-file)
       (status-reporter fetch-log)

       ;; Install egg
       (when (zero? (report-status fetch-log))
         (progress-indicator 'install egg)
         (let ((install-log (salmonella 'install egg)))
           (log! install-log log-file)
           (status-reporter install-log)

           (when (zero? (report-status install-log))
             ;; Check version
             (progress-indicator 'check-version egg)
             (let ((check-version-log (salmonella 'check-version egg)))
               (log! check-version-log log-file)
               (status-reporter check-version-log))

             ;; Test egg
             (progress-indicator 'test egg)
             (let ((test-log (salmonella 'test egg)))
               (log! test-log log-file)
               (status-reporter test-log)))))))
   eggs)

  (log! (make-report #f 'end 0 "" (current-seconds)) log-file)
  (show-statistics log-file)
  (delete-path tmp-dir))
