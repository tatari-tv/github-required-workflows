.DEFAULT_GOAL := dev

.PHONY: all
all: clean dev lint

# Dev
.PHONY: dev
dev:
	poetry install

# Testing related targets
.PHONY: lint
lint:
	poetry run pre-commit run --all-files


# Clean
.PHONY: clean
clean:
	rm -rf build/ dist/ .tox/ .venv/ .mypy_cache/ .pytest_cache/
	rm -rf *.egg-info
	rm -rf .coverage
	find . -name '__pycache__' -delete
	find . -name '*.pyc' -delete
