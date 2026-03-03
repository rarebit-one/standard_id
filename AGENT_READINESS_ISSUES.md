# Agent Readiness Improvement Issues

**Project:** standard_id  
**Current Level:** 2/5 (39% pass rate)  
**Target:** Level 3 (40-60% pass rate)

---

## 🔴 P1: Critical (Required for Level 3)

### 1. Create AGENTS.md file for AI agent documentation

**Why:** AGENTS.md is the primary documentation file that AI agents use to understand how to work with the codebase. This is the #1 blocker for agent productivity.

**What:**
Create an AGENTS.md file at the repository root documenting:
- Build commands (`bundle install`)
- Test commands (`bundle exec rspec`)
- Development workflow
- Project-specific conventions
- Common tasks and how to accomplish them

**Reference:**
- https://docs.factory.ai/factory-docs/agents-md
- Agent readiness criterion: `agents_md` (Level 2)

**Impact:** This single file will significantly improve AI agent effectiveness by providing essential context about the project.

---

### 2. Enable GitHub secret scanning

**Why:** Secret scanning is currently disabled. This leaves the repository vulnerable to accidentally committed secrets, API keys, and credentials.

**What:**
Enable GitHub Advanced Security secret scanning:
1. Go to Settings → Code security and analysis
2. Enable "Secret scanning"
3. Enable "Secret scanning push protection"

**Impact:** Prevents accidental exposure of sensitive credentials in the repository.

**Reference:**
- Agent readiness criterion: `secret_scanning` (Level 3)
- Current status: Disabled (verified via API)

---

### 3. Enable GitHub code scanning (CodeQL)

**Why:** Code scanning is currently disabled. This means we're missing automated security vulnerability detection (SAST).

**What:**
Enable GitHub Advanced Security code scanning:
1. Go to Settings → Code security and analysis
2. Enable "Code scanning"
3. Set up CodeQL analysis workflow
4. Configure to run on PRs and pushes to main

**Impact:** Automatically detects security vulnerabilities, bugs, and code quality issues before they reach production.

**Reference:**
- Agent readiness criterion: `automated_security_review` (Level 2)
- Current status: Disabled (verified via API)

---

### 4. Configure branch protection rules for main

**Why:** The main branch has no protection rules, allowing direct pushes and potentially breaking changes without review.

**What:**
Configure branch protection for the `main` branch:
1. Go to Settings → Branches → Branch protection rules
2. Add rule for `main`
3. Enable:
   - Require pull request reviews before merging (at least 1 approval)
   - Require status checks to pass (lint, test)
   - Require branches to be up to date before merging
   - Include administrators (optional but recommended)

**Impact:** Ensures all changes go through CI and review, preventing accidental breaking changes.

**Reference:**
- Agent readiness criterion: `branch_protection` (Level 2)
- Current status: No protection rules (verified via API)

---

## 🟡 P2: High Priority

### 5. Add test coverage thresholds with SimpleCov

**Why:** No coverage thresholds are enforced, allowing test coverage to regress without warning.

**What:**
1. Add `simplecov` gem to Gemfile (test group)
2. Configure SimpleCov in `spec/spec_helper.rb`:
   ```ruby
   require 'simplecov'
   SimpleCov.start 'rails' do
     minimum_coverage 80
     minimum_coverage_by_file 60
   end
   ```
3. Add coverage reports to .gitignore
4. Consider adding coverage badge to README

**Impact:** Prevents regression in test coverage and ensures new code is properly tested.

**Reference:**
- Agent readiness criterion: `test_coverage_thresholds` (Level 2)
- Current status: No thresholds configured

---

### 6. Create .env.example template file

**Why:** No .env.example file exists, making it unclear what environment variables the project needs for development.

**What:**
Create `.env.example` file documenting all environment variables:
- Any OAuth client IDs/secrets for social providers (with dummy values)
- Database configuration (if needed beyond defaults)
- Any other configuration that can be set via environment variables

Even if most variables are optional, documenting them helps developers and agents understand configuration options.

**Impact:** Helps developers and AI agents quickly understand what environment configuration is available/required.

**Reference:**
- Agent readiness criterion: `env_template` (Level 1)
- Current status: No .env.example file

---

### 7. Add issue templates for bugs and features

**Why:** No issue templates exist, making it harder for contributors to provide complete information when reporting issues.

**What:**
Create `.github/ISSUE_TEMPLATE/` directory with templates:
1. `bug_report.yml` - For bug reports
2. `feature_request.yml` - For feature requests
3. `config.yml` - Template configuration

Templates should include sections for:
- Description
- Steps to reproduce (for bugs)
- Expected vs actual behavior
- Environment details
- Additional context

**Impact:** Standardizes issue reporting and helps agents understand what information to provide when creating issues.

**Reference:**
- Agent readiness criterion: `issue_templates` (Level 2)
- Current status: No issue templates

---

### 8. Create pull request template

**Why:** No PR template exists, leading to inconsistent PR descriptions and missing important information.

**What:**
Create `.github/pull_request_template.md` with sections:
- Description of changes
- Type of change (bug fix, feature, refactor, etc.)
- Testing done
- Breaking changes (if any)
- Checklist:
  - [ ] Tests added/updated
  - [ ] Documentation updated
  - [ ] CHANGELOG updated (if applicable)

**Impact:** Ensures PRs (including agent-generated ones) include necessary context for reviewers.

**Reference:**
- Agent readiness criterion: `pr_templates` (Level 2)
- Current status: No PR template

---

### 9. Add CODEOWNERS file

**Why:** No CODEOWNERS file exists, making it unclear who should review changes to different parts of the codebase.

**What:**
Create `.github/CODEOWNERS` file defining code ownership:
```
# Default owners for everything
* @jaryl

# Core authentication logic
/lib/standard_id/ @jaryl

# Models
/app/models/ @jaryl

# OAuth flows
/lib/standard_id/oauth/ @jaryl
```

**Impact:** Automatically assigns reviewers to PRs based on files changed, ensuring the right people review changes.

**Reference:**
- Agent readiness criterion: `codeowners` (Level 2)
- Current status: No CODEOWNERS file

---

## 🟢 P3: Medium Priority

### 10. Configure pre-commit hooks with Overcommit

**Why:** No pre-commit hooks are configured, meaning code quality checks only run in CI rather than catching issues locally.

**What:**
1. Add `overcommit` gem to Gemfile (development group)
2. Create `.overcommit.yml` configuration:
   ```yaml
   PreCommit:
     RuboCop:
       enabled: true
       on_warn: fail
   ```
3. Document in AGENTS.md: `overcommit --install`

**Impact:** Catches linting issues before commit, speeding up the development feedback loop.

**Reference:**
- Agent readiness criterion: `pre_commit_hooks` (Level 2)
- Current status: No pre-commit hooks configured

---

### 11. Enable RuboCop complexity metrics

**Why:** No cyclomatic complexity analysis is configured, allowing overly complex methods to slip through.

**What:**
Add to `.rubocop.yml`:
```yaml
Metrics/CyclomaticComplexity:
  Enabled: true
  Max: 10

Metrics/PerceivedComplexity:
  Enabled: true
  Max: 10

Metrics/MethodLength:
  Enabled: true
  Max: 25
```

**Impact:** Prevents overly complex code that is hard to understand and maintain.

**Reference:**
- Agent readiness criterion: `cyclomatic_complexity` (Level 5)
- Current status: No complexity analysis configured

---

### 12. Configure release automation with release-please

**Why:** No release automation exists, making the release process manual and error-prone.

**What:**
Set up release-please GitHub Action:
1. Create `.github/workflows/release.yml`
2. Configure release-please to:
   - Track conventional commits
   - Auto-generate CHANGELOG.md
   - Create release PRs
   - Publish gem to RubyGems on merge

**Impact:** Automates version bumping, changelog generation, and gem publishing.

**Reference:**
- Agent readiness criterion: `release_automation` (Level 3)
- Current status: No automation configured

---

### 13. Add coverage reporting to PRs with SimpleCov + Codecov

**Why:** Coverage is tracked but not reported on PRs, making it hard to see if changes improve/reduce coverage.

**What:**
1. Sign up for Codecov
2. Add `codecov` gem
3. Create `.github/workflows/coverage.yml` to upload reports
4. Configure Codecov to comment on PRs with coverage changes

**Impact:** Makes test coverage visible in PR reviews, encouraging developers to maintain/improve coverage.

**Reference:**
- Agent readiness criterion: `code_quality_metrics` (Level 4)
- Current status: No coverage reporting on PRs

---

### 14. Add architecture documentation with Mermaid diagrams

**Why:** No architecture documentation exists, making it harder for new contributors and agents to understand the system design.

**What:**
Create `docs/architecture.md` with Mermaid diagrams showing:
- OAuth flow architecture
- Session management (STI hierarchy: BrowserSession, DeviceSession, ServiceSession)
- Authentication flows (web vs API)
- Event system architecture

**Impact:** Helps developers and agents understand how different components work together.

**Reference:**
- Agent readiness criterion: `service_flow_documented` (Level 3)
- Current status: No architecture diagrams

---

## 🔵 P4: Lower Priority

### 15. Set up technical debt tracking with TODO enforcement

**Why:** No technical debt tracking exists, allowing TODO comments to accumulate without accountability.

**What:**
Options:
1. **Simple**: Add CI check requiring TODO comments to reference issues: `# TODO(#123): ...`
2. **Advanced**: Add `todo_or_die` gem to enforce TODO cleanup

Recommended approach:
```ruby
# Add to CI
bundle exec rake todo_check  # Custom rake task to verify TODO format
```

**Impact:** Ensures technical debt is tracked and visible in issue tracker.

**Reference:**
- Agent readiness criterion: `tech_debt_tracking` (Level 3)
- Current status: No TODO tracking

---

### 16. Configure unused dependency detection with bundler-audit

**Why:** No unused dependency detection exists, potentially leaving unused gems in the Gemfile.

**What:**
1. Add CI check for unused dependencies:
   ```yaml
   - name: Check for unused dependencies
     run: bundle exec bundler-audit check --update
   ```
2. Consider adding `bundler-leak` for security scanning

**Impact:** Keeps dependencies lean and reduces security surface area.

**Reference:**
- Agent readiness criterion: `unused_dependencies_detection` (Level 3)
- Current status: No dependency checking

---

### 17. Add dead code detection with debride

**Why:** No dead code detection configured, allowing unused methods to accumulate.

**What:**
1. Add `debride` gem to Gemfile (development group)
2. Add CI check: `bundle exec debride lib/`
3. Configure exclusions for known false positives

**Impact:** Identifies and removes unused code, reducing maintenance burden.

**Reference:**
- Agent readiness criterion: `dead_code_detection` (Level 3)
- Current status: No dead code detection

---

### 18. Add duplicate code detection with flay

**Why:** No duplicate code detection configured, allowing copy-paste code to slip through.

**What:**
1. Add `flay` gem to Gemfile (development group)
2. Add CI check: `bundle exec flay lib/`
3. Set reasonable thresholds for similarity

**Impact:** Identifies duplicate code that should be refactored into shared methods.

**Reference:**
- Agent readiness criterion: `duplicate_code_detection` (Level 3)
- Current status: No duplicate code detection

---

### 19. Add large file detection to CI

**Why:** No large file detection configured, potentially allowing large files to be committed.

**What:**
Add CI check to detect large files:
```yaml
- name: Check for large files
  run: |
    find . -type f -size +1M -not -path "*/node_modules/*" -not -path "*/.git/*"
    if [ $? -eq 0 ]; then exit 1; fi
```

**Impact:** Prevents accidentally committing large files that should be in LFS or excluded.

**Reference:**
- Agent readiness criterion: `large_file_detection` (Level 3)
- Current status: No large file detection

---

### 20. Configure Factory skills directory

**Why:** No skills configured, missing opportunity for reusable agent workflows.

**What:**
Create `.factory/skills/` directory with common tasks:
1. `run-tests/SKILL.md` - Running the test suite
2. `add-feature/SKILL.md` - Adding a new feature with tests
3. `fix-rubocop/SKILL.md` - Fixing RuboCop violations

**Impact:** Provides reusable workflows for common agent tasks.

**Reference:**
- Agent readiness criterion: `skills` (Level 3)
- Current status: No skills configured
- See: https://code.claude.com/docs/en/skills

---

## Summary

**Immediate Actions (Do First):**
1. Create AGENTS.md (biggest impact)
2. Enable GitHub security features (secret scanning, code scanning, branch protection)
3. Add test coverage thresholds
4. Create .env.example

**Week 1-2:**
5-9. Add templates and CODEOWNERS

**Week 3-4:**
10-14. Improve code quality tooling and automation

**Future:**
15-20. Polish and optimization

**Expected Outcome:** Moving from Level 2 (39%) to Level 3 (40-60%) by completing P1-P2 items.
