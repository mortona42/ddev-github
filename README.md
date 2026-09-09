# ddev-github <!-- omit in toc -->

[![tests](https://github.com/mortona42/ddev-gh/actions/workflows/tests.yml/badge.svg)](https://github.com/mortona42/ddev-gh/actions/workflows/tests.yml)

Installs the [GitHub CLI](https://cli.github.com/) and the
[`gh stack`](https://github.com/github/gh-stack) stacked-pull-request extension
inside the DDEV web container, and keeps your login in the project so you only
have to do it once.

## Installation

```shell
ddev add-on get mortona42/ddev-github
ddev restart
```

Installation asks how you want `gh` to authenticate — see
[Authenticating](#authenticating). If you install non-interactively (in CI, or
with `DDEV_NONINTERACTIVE=true`) it keeps the defaults and you can run the
dialog later with `ddev gh-setup`.

## Usage

Run the GitHub CLI in the web container with `ddev gh`:

```shell
ddev gh auth login          # first-time setup
ddev gh pr list
ddev gh pr create --fill
ddev gh stack init          # stacked PRs -- see "Stacked pull requests" below
```

`ddev gh-setup` reconfigures how that login is stored and obtained.

Everything in the container shares the same login, so `gh` also works from
`ddev ssh`, from project scripts, and from coding agents running in the
container.

### Authenticating

There is more than one reasonable answer here — a login stored in the project, a
copy of the one you already have on the host, or a token in the environment — so
the add-on asks instead of picking for you. The dialog runs during
`ddev add-on get`, and again whenever you want to change your mind:

```shell
ddev gh-setup
```

It asks two things: **where** the login should live (`.ddev/gh` by default,
another directory in the project, or nowhere at all if you'd rather use a
token), and **how** to get one (copy the host's, log in through DDEV, or paste a
token). `ddev gh-setup --show` prints what is currently configured.

Everything it does is also available as flags, for scripts and CI:

```shell
ddev gh-setup --show                  # report the current configuration
ddev gh-setup --dir=.ddev/gh          # store the login here (the default)
ddev gh-setup --dir=config/gh         # ...or anywhere else in the project
ddev gh-setup --no-dir                # don't store it; use GH_TOKEN instead
ddev gh-setup --copy-host             # copy the host's login into that directory
ddev gh-setup --copy-host --global    # ...and share any recovered token machine-wide
gh auth token | ddev gh-setup --token-stdin           # this project
gh auth token | ddev gh-setup --token-stdin --global  # every project
```

Changing any of this edits `.ddev/config.gh.yaml`, so run `ddev restart`
afterwards. If you choose anything other than the default directory, `gh-setup`
drops the `#ddev-generated` marker from that file so a later `ddev add-on get`
won't overwrite your choice — the trade-off being that add-on updates then skip
the file, and you re-run `ddev gh-setup` to pick them up.

#### A login stored in the project

This is the default. `GH_CONFIG_DIR` points at `.ddev/gh`, so your token and
config persist across `ddev restart`, image rebuilds, and `ddev delete`, and are
shared by everything in the container. `.ddev/gh/.gitignore` keeps `hosts.yml`
(the token) and `config.yml` out of git — **do not remove it**.

Logging in is interactive, so a start-up hook can't do it; the add-on just tells
you on `ddev start` when it hasn't happened, naming whichever fix applies to how
you've configured things:

```shell
ddev gh auth login
```

The container has no browser, so choose the "Login with a web browser" flow and
`gh` prints a one-time code plus a URL to open on your host. A personal access
token pasted at the prompt works too.

#### Copying the login from the host

`ddev gh-setup --copy-host` copies `~/.config/gh/hosts.yml` (and `config.yml`, if
the project has none) into the configured directory.

If `gh` on your host keeps its token in the OS keyring rather than in
`hosts.yml`, the copied file has no credential in it. `gh-setup` notices and asks
the host's own `gh` for the token — `gh auth token`, the only way back out of a
keyring — and stores it as an environment variable instead. That is the same
thing as doing it by hand:

```shell
gh auth token | ddev gh-setup --token-stdin
```

The dialog asks before doing this, because the token ends up in a plain file
rather than in the keyring; `--copy-host` on the command line just does it and
says so. Add `--global` to put the token in DDEV's global config instead of this
project's. A `github.com` token goes to `GH_TOKEN` and a GitHub Enterprise Server
one to `GH_ENTERPRISE_TOKEN`, which is what `gh` reads for each. If the keyring
can't be reached — no `gh` on the host, or it's locked — nothing is written and
`gh-setup` says why.

Either way what you get is a **snapshot**, and it goes stale for reasons that
have nothing to do with expiry. A token from `gh auth login` is an OAuth App
token with no expiry date at all (GitHub revokes one only after a year unused,
or when you or an org admin revokes it); a classic PAT expires when you said it
would, a fine-grained one within a year. But `gh auth refresh` on the host mints
a *new* token, and `gh auth logout` removes the host's copy without revoking
yours — in both cases the project keeps the old one. Re-run `ddev gh-setup
--copy-host` after either. To check what you actually have:

```shell
gh api -i user | grep -i github-authentication-token-expiration   # absent = no expiry
```

#### A token instead

For CI, or if you'd rather keep no credential in the project at all, set
`GH_TOKEN` for the web container. `ddev gh-setup --token-stdin` writes it to
`.ddev/.env.web` with mode 600 and adds that path to your `.gitignore`; `--global`
puts it in DDEV's global config instead, for every project on the machine. By
hand:

```shell
echo 'GH_TOKEN=ghp_...' > .ddev/.env.web
echo '.ddev/.env.web' >> .gitignore
ddev restart
```

`GH_TOKEN` takes precedence over a stored login, which is worth remembering when
something breaks: a stale one silently shadows a perfectly good login in
`.ddev/gh`, and `gh auth login` refuses to run at all while one is set. The
start-up notice takes this into account — with a token in the environment it
tells you the token is the problem instead of sending you to `ddev gh auth
login`, which could not have helped.

### Why not `homeadditions`?

DDEV copies `.ddev/homeadditions/` into the container's home directory on start.
That is a one-way copy: a `gh auth login` done in the container, a refreshed
token, a `gh auth logout` — none of it comes back to the host, and the copy is
redone on every start, so a login made in the container gets reverted by the
stale host copy at the next `ddev restart`. Sharing the host's login that way
would also mean putting a live OAuth token in a directory whose whole convention
is "commit this so your team gets it". A bind-mounted `GH_CONFIG_DIR` inside the
project is bidirectional and needs no copy at all.

### Pushing branches

`gh` authenticates API calls, but `git push` is a separate matter. Either let
`gh` act as git's credential helper for HTTPS remotes:

```shell
ddev gh auth setup-git
```

...or use SSH, which works out of the box once you've run `ddev auth ssh` on the
host to load your keys into DDEV's SSH agent.

## Stacked pull requests

[`gh stack`](https://github.com/github/gh-stack) breaks a large change into a
chain of pull requests that build on each other. It's installed with the CLI, so
it's there after `ddev restart`:

```shell
ddev gh stack init                       # start a stack on your default branch
ddev gh stack add my-next-branch         # add a branch to the stack
ddev gh stack submit                     # push and create/update the PRs
ddev gh stack                            # full command list
```

Because it pushes branches, `gh stack submit` needs working git authentication —
see [Pushing branches](#pushing-branches).

## Updating

`gh` is installed into the web container image, so it's pinned to whatever
version was current when the image was built. Rebuild to pick up a new one:

```shell
ddev restart --no-cache
```

The `gh stack` extension is in the image too, and a rebuild reinstalls the
latest. To update it in the running container without a rebuild:

```shell
ddev gh extension upgrade --all
```

That's instant, but lives only in the running container and is lost on the next
rebuild.

### Why not `webimage_extra_packages`?

Because `webimage_extra_packages: [gh]` installs Debian's package, which trixie
froze at 2.46.0 and never bumps. This add-on adds GitHub's own apt repo instead,
so you track upstream releases. If you previously added `gh` to
`webimage_extra_packages` in `.ddev/config.yaml`, remove it — the two will fight
over the same binary.

## Where things live

| Path | What |
| --- | --- |
| `.ddev/gh/` | Your `gh` config and credentials (`GH_CONFIG_DIR`), gitignored |
| `.ddev/config.gh.yaml` | Points `GH_CONFIG_DIR` at the project; start-up checks |
| `.ddev/web-build/Dockerfile.gh` | Installs `gh` and the `gh-stack` extension |
| `.ddev/commands/web/gh` | The `ddev gh` command |
| `.ddev/commands/host/gh-setup` | The `ddev gh-setup` command |
| `.ddev/.env.web` | `GH_TOKEN` / `GH_ENTERPRISE_TOKEN`, if you chose the token route |

`.ddev/gh/` is only the default; `ddev gh-setup --show` reports where your login
actually lives.

The `gh stack` extension binary lives in the image at
`~/.local/share/gh/extensions/`, not in `.ddev/gh/`, so it never lands in your
repository.

### Git worktrees

If you use per-worktree DDEV projects, copy `.ddev/gh` into the new worktree to
carry the login across (or use a global `GH_TOKEN`, which every worktree picks up
for free). With
[ddev-worktrees](https://github.com/mortona42/ddev-worktrees), add it to
`.ddev/worktree-hooks.yaml`:

```yaml
profiles:
  default:
    copy:
      - .ddev/gh
```

## Removing

```shell
ddev add-on remove gh
```

This removes the add-on's files but deliberately leaves your `gh` config
directory alone rather than deleting your login. Removal prints the path if
anything is still there. `ddev gh auth logout` goes with the add-on, so delete
the credentials by hand once you're done with them — at the default location:

```shell
rm -rf .ddev/gh
```

The `.gitignore` that kept them out of git was part of the add-on and goes too,
so until you delete them the token is one `git add` from being committed.

**Contributed and maintained by [@mortona42](https://github.com/mortona42)**
