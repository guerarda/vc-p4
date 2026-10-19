EMACS ?= emacs

.PHONY: compile clean
compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile vc-p4.el
clean:
	rm -f vc-p4.elc
