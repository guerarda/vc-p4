EMACS ?= emacs
PYTHON ?= python3
FLYCHECK_DIR ?=
DIFF_HL_DIR ?=

.PHONY: check compile test test-diff-hl test-flycheck integration clean
check: compile test
compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile vc-p4.el vc-p4-ops.el vc-p4-gutter.el
test:
	$(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' -L . -L test -l vc-p4-operation-tests -f ert-run-tests-batch-and-exit
test-diff-hl:
	@test -n "$(DIFF_HL_DIR)" || (echo 'Set DIFF_HL_DIR to a diff-hl checkout'; exit 1)
	$(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' -L . -L test -L '$(DIFF_HL_DIR)' -l vc-p4-responsive-tests -f ert-run-tests-batch-and-exit
test-flycheck:
	@test -n "$(DIFF_HL_DIR)" -a -n "$(FLYCHECK_DIR)" || (echo 'Set DIFF_HL_DIR and FLYCHECK_DIR'; exit 1)
	$(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' -L . -L test -L '$(DIFF_HL_DIR)' -L '$(FLYCHECK_DIR)' -l vc-p4-flycheck-tests --eval '(ert-run-tests-batch-and-exit "vc-p4-flycheck")'
integration:
	$(PYTHON) scripts/p4_fixture.py --emacs '$(EMACS)'
clean:
	rm -f vc-p4.elc vc-p4-ops.elc vc-p4-gutter.elc
