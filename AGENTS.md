# Repository Guidelines

## Project Structure & Module Organization
This repository is currently a blank bootstrap project. Keep the top level clean and add code under a dedicated `src/` directory as features are introduced. Place automated tests in `tests/`, static assets in `assets/`, and developer scripts in `scripts/`. Mirror source paths in tests when practical, for example `src/bot/router.py` with `tests/test_router.py`.

## Build, Test, and Development Commands
No build or test toolchain is configured yet. When you add one, expose the common workflows through documented, repeatable commands and keep them stable.

- `make setup`: install local dependencies and initialize tooling.
- `make test`: run the full test suite.
- `make lint`: run formatting and static analysis.
- `make dev`: start the primary local development entry point.

If `make` is not used, document the equivalent direct commands in this file and the project `README`.

## Coding Style & Naming Conventions
Use 4 spaces for indentation in source files unless a formatter for the chosen language enforces something else. Prefer small, single-purpose modules and descriptive names. Use `snake_case` for files and functions, `PascalCase` for classes, and `UPPER_SNAKE_CASE` for constants. Add a formatter and linter early (for example, `ruff` for Python or `eslint` + `prettier` for JavaScript) and run them before opening a pull request.

## Testing Guidelines
Add automated tests with each feature or bug fix. Name test files `test_<module>.py` or `<module>.test.ts`, depending on the language you introduce, and keep tests deterministic. Aim for meaningful coverage of core flows, edge cases, and failure paths. Wire the canonical test command into `make test` or an equivalent single command.

## Commit & Pull Request Guidelines
There is no Git history in this directory yet, so no established commit convention exists. Start with short, imperative commit subjects such as `Add router skeleton` or `Set up test harness`. Keep commits focused on one change. Pull requests should include a clear summary, testing notes, and links to related issues. Include screenshots or sample output when UI or CLI behavior changes.

## Security & Configuration Tips
Do not commit secrets, local credentials, or generated environment files. Keep developer-specific values in ignored files such as `.env.local`, and document required variables in `README.md` once the application needs them.
