EMACS ?= emacs

.PHONY: all compile lint checkdoc package-lint test clean

all: compile lint test

compile:
	$(EMACS) -Q --batch -l test/batch-compile.el

lint: checkdoc package-lint

checkdoc:
	$(EMACS) -Q --batch -l test/batch-checkdoc.el

package-lint:
	$(EMACS) -Q --batch -l test/batch-package-lint.el

test:
	$(EMACS) -Q --batch -L . -L test \
		-l test/keydrill-engine-test.el \
		-l test/keydrill-live-test.el \
		-l test/keydrill-observe-test.el \
		-l test/keydrill-store-test.el \
		-l test/keydrill-capture-test.el \
		-l test/keydrill-ui-test.el \
		-l test/keydrill-deck-test.el \
		-f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
