# Directories
SCRIPTS_DIR := .
TEST_DIR := test

# Tools
FORMATTER := shfmt
TEST_RUNNER := bats

# Default target
.PHONY: all
all: check test

# Check formatting (no changes)
# TODO add test dir to formatter call
.PHONY: check
check:
	@echo "Checking code format..."
	@$(FORMATTER) -d $(SCRIPTS_DIR)/*.sh || (echo "Formatting issues found. Run 'make format' to fix." && exit 1)
	@echo "All files properly formatted."

# Auto-format scripts and tests
# TODO add test dir to formatter call
.PHONY: format
format:
	@echo "Formatting code..."
	@$(FORMATTER) -w $(SCRIPTS_DIR)/*.sh
	@echo "Formatting complete."

# Run tests
.PHONY: test
test:
	@echo "Running tests..."
	@$(TEST_RUNNER) $(TEST_DIR)
	@echo "All tests passed."

# Clean temporary files (optional)
.PHONY: clean
clean:
	@echo "Cleaning temporary files..."
	@find $(TEST_DIR) -type f -name '*.tmp' -delete
	@echo "Cleanup done."
