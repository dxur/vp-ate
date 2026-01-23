.PHONY: test

ARGS := $(filter-out $@,$(MAKECMDGOALS))

test:
	@./test.py $(filter-out $@,$(MAKECMDGOALS))

%:
	@: