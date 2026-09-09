#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure

setup() {
  set -eu -o pipefail

  # When CI is re-run with debug logging (RUNNER_DEBUG=1), make `run` print the
  # $output of every command on failure. This surfaces the post-start hook log
  # captured by `run ddev restart`, which is otherwise swallowed on success.
  [ "${RUNNER_DEBUG:-}" = "1" ] && export BATS_VERBOSE_RUN=1

  # Override this variable for your add-on:
  export GITHUB_REPO=mortona42/ddev-gh

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH:-}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats:/usr/local/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site --omit-containers db,ddev-ssh-agent
  assert_success
  run ddev start -y
  assert_success
}

# DDEV runs post-start hooks non-fatally: a failing hook is logged but the command
# still exits 0. Assert the preceding command's output reported no failed hook, so a
# silently-broken hook is caught at the source.
refute_hook_failure() {
  refute_output --partial "Task failed"
}

# Where the gh-stack extension lives inside the web container. Extensions go in the
# user's data dir, deliberately outside GH_CONFIG_DIR, so they stay in the image
# rather than landing in the project directory. Kept unexpanded on purpose: the
# container's shell resolves it, not the host's.
GH_STACK_DIR='${XDG_DATA_HOME:-$HOME/.local/share}/gh/extensions/gh-stack'

health_checks() {
  # The point of the add-on: `ddev gh` runs the GitHub CLI in the web container.
  # --version needs neither auth nor a repo, so it just proves the binary is
  # installed and on PATH.
  run ddev gh --version
  assert_success
  assert_output --partial "gh version"

  # Debian trixie freezes gh at 2.46.0, which is why the add-on builds from
  # GitHub's apt repo instead of using webimage_extra_packages. If we ever get
  # 2.46.0, the build silently fell back to the distro package.
  refute_output --partial "gh version 2.46.0"

  # The gh-stack extension is baked into the image and reachable as `gh stack`.
  run ddev exec gh stack --version
  assert_success
  assert_output --partial "gh stack version"

  # The setup dialog is a host command, so it must be registered with ddev too.
  run ddev gh-setup --show
  assert_success
  assert_output --partial "GitHub CLI add-on configuration"
}

# The login lives in the project at .ddev/gh so it is shared by everything in the
# container and survives rebuilds. Verify both directions through gh's OWN reads and
# writes rather than by inspecting the environment variable.
assert_config_round_trips() {
  # Host -> container: seed a value into the persisted config and confirm gh, running
  # in the container, reads it back. `editor` is a convenient probe: plain config that
  # needs no auth and has no side effects.
  mkdir -p "${TESTDIR}/.ddev/gh"
  cat > "${TESTDIR}/.ddev/gh/config.yml" <<'EOF'
version: 1
editor: ddev-host-marker
EOF
  run ddev exec gh config get editor
  assert_success
  assert_output --partial "ddev-host-marker"

  # Container -> host: write config via gh and confirm it lands back in the host-side
  # file, so an interactive `gh auth login` persists into the project.
  run ddev exec gh config set editor ddev-container-marker
  assert_success
  run cat "${TESTDIR}/.ddev/gh/config.yml"
  assert_success
  assert_output --partial "ddev-container-marker"
}

# The stored OAuth token must never be committable.
assert_credentials_gitignored() {
  assert_file_exist "${TESTDIR}/.ddev/gh/.gitignore"
  run cat "${TESTDIR}/.ddev/gh/.gitignore"
  assert_success
  assert_output --partial "hosts.yml"
  assert_output --partial "config.yml"

  # Prove it through git, not just by reading the file: a token written where gh
  # writes it must be invisible to `git status`.
  git -C "${TESTDIR}" init -q 2>/dev/null || true
  echo "github.com:" > "${TESTDIR}/.ddev/gh/hosts.yml"
  run git -C "${TESTDIR}" status --porcelain --untracked-files=all
  assert_success
  refute_output --partial ".ddev/gh/hosts.yml"
  rm -f "${TESTDIR}/.ddev/gh/hosts.yml"
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  refute_hook_failure
  health_checks
  assert_config_round_trips
  assert_credentials_gitignored
}

# gh is unusable until it is authenticated, and the login is interactive so a hook
# cannot do it. The post-start hook must say so on a fresh, unauthenticated project
# (which is exactly what CI is) rather than leaving a silently broken gh.
@test "post-start reports an unauthenticated gh" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  refute_hook_failure
  assert_output --partial "not authenticated"

  # Once gh is authenticated the notice must stop; a nag on every start would be
  # noise. `gh auth status` validates the token against the API, so this half needs
  # a real one -- available in CI, usually not on a developer's machine.
  [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || skip "no GH_TOKEN/GITHUB_TOKEN to authenticate with"
  cat > "${TESTDIR}/.ddev/.env.web" <<EOF
GH_TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
EOF
  run ddev restart -y
  assert_success
  refute_hook_failure
  refute_output --partial "not authenticated"
  # A valid token must not trip the "token is not valid" branch either.
  refute_output --partial "not valid"
  rm -f "${TESTDIR}/.ddev/.env.web"
}

# `gh auth login` refuses to run while a token is set in the environment, so
# advising it when GH_TOKEN is the thing that is broken sends people in circles.
# The notice has to name the actual problem instead.
@test "post-start advice depends on where the credential comes from" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  # A token that cannot authenticate is enough; no real credential needed.
  echo 'GH_TOKEN=ghp_not_a_real_token_0000000000000000' > "${TESTDIR}/.ddev/.env.web"
  run ddev restart -y
  assert_success
  refute_hook_failure
  assert_output --partial "the token in the environment is not valid"
  assert_output --partial "ddev gh-setup"
  refute_output --partial "run: ddev gh auth login"

  # With no token and a config directory, `ddev gh auth login` IS the answer.
  rm -f "${TESTDIR}/.ddev/.env.web"
  run ddev restart -y
  assert_success
  refute_hook_failure
  assert_output --partial "run: ddev gh auth login"

  # With neither, logging in would land in a container home that the next
  # rebuild wipes, so the answer is to configure something first.
  run ddev gh-setup --no-dir
  assert_success
  run ddev restart -y
  assert_success
  refute_hook_failure
  assert_output --partial "no login is being persisted"
  refute_output --partial "run: ddev gh auth login"
}

# The extension is installed during the image build, where an unauthenticated GitHub
# API rate limit can plausibly fail it. The post-start hook is the recovery path, so
# simulate that failure by deleting the extension and restarting.
@test "post-start reinstalls a missing gh-stack extension" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  refute_hook_failure

  # Remove the extension the build installed, and confirm it is really gone.
  run ddev exec "rm -rf ${GH_STACK_DIR}"
  assert_success
  run ddev exec gh stack --version
  assert_failure

  # The hook should notice and reinstall it.
  run ddev restart -y
  assert_success
  refute_hook_failure
  run ddev exec gh stack --version
  assert_success
  assert_output --partial "gh stack version"
}

# `ddev gh-setup` regenerates config.gh.yaml rather than patching it, so the file
# shipped in the add-on has to be exactly what the script writes for the default
# directory. If they ever drift, installing and immediately re-running the setup
# would silently rewrite the user's config.
@test "the shipped config.gh.yaml is what gh-setup generates by default" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  run ddev gh-setup --dir=.ddev/gh
  assert_success
  run diff "${DIR}/config.gh.yaml" "${TESTDIR}/.ddev/config.gh.yaml"
  assert_success
}

@test "gh-setup reports the current configuration" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  run ddev gh-setup --show
  assert_success
  assert_output --partial ".ddev/gh  ->  /var/www/html/.ddev/gh"
  assert_output --partial "config.gh.yaml is add-on managed"
}

# The whole point of asking where the login goes is that the answer reaches gh in
# the container, so assert it there rather than in the YAML.
@test "gh-setup moves the config directory" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  run ddev gh-setup --dir=config/gh
  assert_success
  assert_file_exist "${TESTDIR}/config/gh/.gitignore"

  # Deviating from the default must drop #ddev-generated, or the next
  # `ddev add-on get` would quietly throw the choice away.
  run head -n1 "${TESTDIR}/.ddev/config.gh.yaml"
  refute_output --partial "#ddev-generated"

  run ddev restart -y
  assert_success
  refute_hook_failure
  run ddev exec printenv GH_CONFIG_DIR
  assert_success
  assert_output --partial "/var/www/html/config/gh"

  # And back again -- re-running with the default restores the add-on-managed file.
  run ddev gh-setup --dir=.ddev/gh
  assert_success
  run head -n1 "${TESTDIR}/.ddev/config.gh.yaml"
  assert_output --partial "#ddev-generated"
}

# --no-dir must remove the variable, not blank it: an empty web_environment list
# in config.gh.yaml would be merged over the rest of the project's environment.
@test "gh-setup --no-dir stops persisting the config into the project" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  run ddev gh-setup --no-dir
  assert_success
  assert_output --partial "not persisted"
  run grep -E '^[[:space:]]*-[[:space:]]*GH_CONFIG_DIR=' "${TESTDIR}/.ddev/config.gh.yaml"
  assert_failure
  run grep -E '^web_environment:' "${TESTDIR}/.ddev/config.gh.yaml"
  assert_failure

  run ddev restart -y
  assert_success
  refute_hook_failure
  run ddev exec 'printenv GH_CONFIG_DIR || echo unset'
  assert_output --partial "unset"
}

# A token written by gh-setup must land in the container as GH_TOKEN and must be
# unstageable, since .ddev/.gitignore does not cover .env.web.
@test "gh-setup --token-stdin stores a token safely" {
  set -eu -o pipefail
  git -C "${TESTDIR}" init -q
  run ddev add-on get "${DIR}"
  assert_success

  run bash -c 'printf %s ghp_bats_fake_token | ddev gh-setup --token-stdin'
  assert_success
  assert_file_exist "${TESTDIR}/.ddev/.env.web"
  run stat -c '%a' "${TESTDIR}/.ddev/.env.web"
  assert_output "600"
  run git -C "${TESTDIR}" status --porcelain --untracked-files=all
  assert_success
  refute_output --partial ".ddev/.env.web"

  run ddev restart -y
  assert_success
  run ddev exec printenv GH_TOKEN
  assert_success
  assert_output --partial "ghp_bats_fake_token"
}

# gh follows GH_CONFIG_DIR on the host too, which lets the test stand in a fake
# host login rather than depending on whoever is running the suite being logged in.
@test "gh-setup --copy-host brings the host login into the project" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  local fake="${TESTDIR}/fake-host-gh"
  mkdir -p "${fake}"
  cat > "${fake}/hosts.yml" <<'EOF'
github.com:
    oauth_token: gho_bats_fake_token
    user: someone
EOF

  GH_CONFIG_DIR="${fake}" run ddev gh-setup --copy-host
  assert_success
  run cat "${TESTDIR}/.ddev/gh/hosts.yml"
  assert_output --partial "gho_bats_fake_token"
  run stat -c '%a' "${TESTDIR}/.ddev/gh/hosts.yml"
  assert_output "600"

  # gh can keep the token in the OS keyring instead, in which case the copied
  # file authenticates nothing. The fallback is to ask the host's own gh for the
  # token -- stub it out, so the test does not need a real keyring or login.
  rm -f "${TESTDIR}/.ddev/gh/hosts.yml" "${TESTDIR}/.ddev/.env.web"
  cat > "${fake}/hosts.yml" <<'EOF'
github.com:
    user: someone
ghe.example.com:
    user: someone
EOF
  mkdir -p "${TESTDIR}/stub-bin"
  cat > "${TESTDIR}/stub-bin/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
  case "$4" in
    github.com) echo "gho_bats_keyring_dotcom"; exit 0 ;;
    ghe.example.com) echo "gho_bats_keyring_ghe"; exit 0 ;;
  esac
fi
exit 1
EOF
  chmod +x "${TESTDIR}/stub-bin/gh"

  PATH="${TESTDIR}/stub-bin:${PATH}" GH_CONFIG_DIR="${fake}" run ddev gh-setup --copy-host
  assert_success
  assert_output --partial "no oauth_token"

  # github.com's token belongs in GH_TOKEN; a GitHub Enterprise Server host's
  # belongs in GH_ENTERPRISE_TOKEN. Putting either in the other authenticates
  # nothing.
  run cat "${TESTDIR}/.ddev/.env.web"
  assert_output --partial "GH_TOKEN=gho_bats_keyring_dotcom"
  assert_output --partial "GH_ENTERPRISE_TOKEN=gho_bats_keyring_ghe"

  run ddev restart -y
  assert_success
  run ddev exec printenv GH_TOKEN
  assert_output --partial "gho_bats_keyring_dotcom"
}

# Nothing to fall back to: no gh on the host means no way into the keyring, and
# guessing or leaving a credential-less hosts.yml in place would both be worse
# than saying so.
@test "gh-setup --copy-host reports when the keyring is unreachable" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  local fake="${TESTDIR}/fake-host-gh"
  mkdir -p "${fake}" "${TESTDIR}/stub-bin"
  cat > "${fake}/hosts.yml" <<'EOF'
github.com:
    user: someone
EOF
  # A gh that cannot produce a token stands in for a locked keyring.
  cat > "${TESTDIR}/stub-bin/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "${TESTDIR}/stub-bin/gh"

  PATH="${TESTDIR}/stub-bin:${PATH}" GH_CONFIG_DIR="${fake}" run ddev gh-setup --copy-host
  assert_output --partial "returned nothing"
  assert_output --partial "No token could be read"
  assert_file_not_exist "${TESTDIR}/.ddev/.env.web"
}

# The container can only see the project directory, so a config dir outside it
# would produce a gh that silently writes into a path nothing else can read.
@test "gh-setup rejects a directory outside the project" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  run ddev gh-setup --dir=/etc/gh
  assert_failure
  run ddev gh-setup --dir=../escape
  assert_failure

  # A rejected directory must not have half-applied.
  run grep -E '^[[:space:]]*-[[:space:]]*GH_CONFIG_DIR=' "${TESTDIR}/.ddev/config.gh.yaml"
  assert_success
  assert_output --partial "/var/www/html/.ddev/gh"
}

# Installation is where most people meet this, and CI installs non-interactively.
# It must keep the shipped defaults instead of hanging on a prompt nobody sees.
@test "a non-interactive install keeps the defaults and says how to reconfigure" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  assert_output --partial "ddev gh-setup"
  run diff "${DIR}/config.gh.yaml" "${TESTDIR}/.ddev/config.gh.yaml"
  assert_success
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  refute_hook_failure
  health_checks
  assert_config_round_trips
  assert_credentials_gitignored
}
