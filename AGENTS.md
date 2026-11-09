# AGENTS.md

`iKnow` is a local, read-only viewer for the macOS personal knowledge graph. This checkout is a fork of [8rank/iKnow](https://github.com/8rank/iKnow); agents never push there, and upstream only ever receives a reviewed branch.

## Branches

- `main` mirrors `upstream/main` exactly and only fast-forwards. Never commit on it.
- `cristoslc/trunk` is the default branch and the personal integration branch: every fork change merges here.
- Branches for upstream come from `scripts/upstream-pr.sh`, which copies chosen commits onto `origin/main` and refuses a commit that carries fork-only material.

## Fork-only paths

Never let these into an upstream-bound commit:

- `pyproject.toml`
- `uv.lock`
- the `.venv/` line in `.gitignore`
- the uv wording in `README.md` and `MANUAL_FOR_YOUR_AGENT.md`

An upstream-bound commit keeps upstream's `python3 server.py` wording.

## Upstream contact

Upstream has never received a pull request and documents issues as its only channel. Open an issue first and offer the branch in it, rather than opening a PR unannounced.

## Run

```sh
uv sync
uv run python server.py
```

`package = false` in `pyproject.toml` is deliberate: `server.py` resolves `public/` and `api/` next to its own file, so an installed copy would look for them inside site-packages.

## Test command

This repo has no automated tests. Verify by hand:

```sh
uv run python server.py --help
uv run python server.py --bundle <dir> --port <port>
curl -i "<token link the server printed>"   # 303, then 200 on the follow
```

The bundle run needs an extracted copy on disk; the live-store run reads the real database and needs Full Disk Access for the terminal.

## Gotcha

Both remotes are on GitHub, so `gh pr list` and `gh pr view` guess the wrong repository here. Every `gh` call needs `--repo cristoslc/iKnow-fork`, or `--repo 8rank/iKnow` when targeting upstream.
