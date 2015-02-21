#lang racket

(require seashell/seashell-config
         seashell/compiler/place
         seashell/git/place)

;; Common file for setting up the testing environment
(define test-dir (build-path (find-system-path 'temp-dir)
                             (format "seashell-test-~a" (random 10000))))

;; Set up test environment.
(if (directory-exists? test-dir)
  (delete-directory/files test-dir)
  (void))
(make-directory test-dir)
(config-set! 'seashell test-dir)
(config-set! 'test-mode #t)

;; Start places.
(seashell-compile-place/init)
(seashell-git-place/init)