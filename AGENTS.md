# AGENTS.md

`iKnow` is a local, read-only viewer for the macOS personal knowledge graph. This checkout is a fork of [8rank/iKnow](https://github.com/8rank/iKnow); agents never push there, and upstream only ever receives a reviewed branch.

## Branches

- `cristoslc/trunk` is the default branch and the personal integration branch: every fork change lands here first.
- `main` mirrors `upstream/main` and only fast-forwards. Never commit on it.
- Upstream-bound work travels on `upstream/<pr-slug>` branches. `scripts/upstream-pr.sh add <slug> <commit>...` cuts the branch from `main`, cherry-picks the chosen trunk commits, and refuses fork-only material. `scripts/upstream-pr.sh push <slug>` sends it to origin and opens the PR from `cristoslc:upstream/<slug>`.
- `scripts/upstream-pr.sh sync` fast-forwards `main` once upstream merges or declines a PR, and reports which branches were left behind.

## Fork-only paths

Never let these into an upstream-bound commit:

- `pyproject.toml`
- `uv.lock`
- the `.venv/` line in `.gitignore`
- the uv wording in `README.md` and `MANUAL_FOR_YOUR_AGENT.md`
- `AGENTS.md` and `scripts/upstream-pr.sh`, which instruct agents about this fork and have no meaning upstream
- `app/` and `scripts/build-app.sh`, the launch app that exists so this Mac can grant Full Disk Access to one program; upstream has no use for it

An upstream-bound commit keeps upstream's `python3 server.py` wording.

The guard runs inside the script, so a hand-run `git push origin upstream/<pr-slug>` bypasses it and must not be done.

## Upstream contact

Upstream has never received a pull request and documents issues as its only channel. Open an issue first and offer the change in it, rather than opening a PR unannounced. The PR comes from `cristoslc:upstream/<pr-slug>`.

## Keeping main in step

When upstream merges or declines a PR, fast-forward `main` and see which branches were left behind:

```sh
scripts/upstream-pr.sh sync
```

`sync` fast-forwards `main` to `upstream/main` and classifies every `upstream/<slug>` branch as merged (safe to delete), current, or stale. Pass `--rebuild <slug>` to re-apply a stale branch's still-pending commits on the new base; that force-pushes the branch with `--force-with-lease`. Nothing is pushed until the guard passes.

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
