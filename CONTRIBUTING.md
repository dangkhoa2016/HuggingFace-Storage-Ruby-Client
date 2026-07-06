# Contributing to HuggingFace Storage

## Code of Conduct

This project and everyone participating in it is governed by the [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## Getting Started

1. Fork the repository on GitHub.
2. Clone your fork locally:
   ```bash
   git clone https://github.com/your-username/hugging_face_storage.git
   cd hugging_face_storage
   ```
3. Set up dependencies:
   ```bash
   bin/setup
   # or manually:
   bundle install
   ```

## Development

The project follows a service-oriented architecture. Each major operation is encapsulated in its own service object with explicit dependency injection.

### Running Tests

```bash
# Run all tests
bin/rspec

# Run a single spec file
bin/rspec spec/hugging_face_storage/file_upload_service_spec.rb

# Run tests matching a pattern
bin/rspec --example "blake3"
```

### Linting

```bash
bundle exec rubocop --parallel
```

### Type Checking

```bash
bundle exec rbs validate
```

### Documentation

```bash
bundle exec yard doc --no-cache
```

## Pull Request Process

1. Ensure all tests pass and line coverage is at 100%.
2. Ensure RuboCop is clean (`bundle exec rubocop --parallel`).
3. Ensure RBS type signatures are valid (`bundle exec rbs validate`).
4. Update `CHANGELOG.md` if your change is user-facing.
5. PRs require review before merging.
6. Squash commits where appropriate.

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` — A new feature
- `fix:` — A bug fix
- `refactor:` — Code change that neither fixes a bug nor adds a feature
- `test:` — Adding or updating tests
- `docs:` — Documentation only changes
- `style:` — Code style changes (formatting, missing semicolons, etc.)
- `ci:` — CI configuration and scripts
- `chore:` — Other changes that don't modify src or test files

## Adding a New Service Object

Service objects follow a consistent pattern:

1. **Inject dependencies** via constructor keyword arguments. Accept shared services (e.g., `api_client`, `config`, `metrics_registry`, `notifications`) rather than relying on global state.

2. **Include `Instrumentation`** if the service should emit metrics or notifications:
   ```ruby
   class MyNewService
     include Instrumentation

     def initialize(api_client:, config:, metrics_registry: nil, notifications: nil, logger: nil)
       @api_client = api_client
       @config = config
       @logger = logger
       instrument(metrics_registry, notifications)
     end
   end
   ```

3. **Write specs** that test the service in isolation using mocks for injected dependencies. Follow the pattern in `spec/hugging_face_storage/` for existing service specs (e.g., `FileUploadService`, `FileDeleteService`).

4. **Register the service** in the relevant manager class (`FileManager`, `DirectoryManager`, or `Client`) with lazy initialization.

## Code Style

- Follow [Ruby Style Guide](https://rubystyle.guide/) as enforced by RuboCop.
- Use `# frozen_string_literal: true` in all source files.
- Use YARD for public API documentation.
- Keep service objects focused — one responsibility per class.
- Prefer composition over inheritance.
