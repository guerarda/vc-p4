EMACS ?= emacs
PYTHON ?= python3
DIFF_HL_DIR ?=

.PHONY: check compile test test-diff-hl integration clean
check: compile test
compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile vc-p4.el
test:
	$(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' -L . -L test -l vc-p4-tests -f ert-run-tests-batch-and-exit
test-diff-hl:
	@test -n "$(DIFF_HL_DIR)" || (echo 'Set DIFF_HL_DIR to a diff-hl checkout'; exit 1)
	$(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' -L . -L test -L '$(DIFF_HL_DIR)' -l vc-p4-responsive-tests -f ert-run-tests-batch-and-exit
integration:
	$(PYTHON) scripts/p4_fixture.py --emacs '$(EMACS)'
clean:
	rm -f vc-p4.elc
