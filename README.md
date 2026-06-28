dnatco-nf
===

A [Nextflow](https://www.nextflow.io) pipeline that runs the **DNATCO standalone tool**
(`dnatco.js`) — a nucleic acid analyzing tool — inside a container, over one or many
coordinate files.

DNATCO performs nucleic-acid backbone conformer validation (NtC/DNATCO) and valence
geometry (NA-VAL) analysis. The full DNATCO web application is available at
[dnatco.datmos.org](https://dnatco.datmos.org); the standalone tool this pipeline wraps is a
command-line, GUI-less version focused on producing validation reports and restraints files.
It is **not** a complete offline replacement for the web application.

What the pipeline adds on top of `dnatco.js`:

- **No local Node.js / build step.** `dnatco.js` runs inside the `node:22` container, so you
  do not install or build it yourself — only a container engine and Nextflow are required.
- **Automatic tool install.** On first run the pipeline downloads the latest dnatco
  standalone release from GitHub into `bin/` (see [Network control](#network-control)).
- **Batch processing.** Point `--input` at a single file or a glob; each structure is
  processed as its own task.
- **Pass-through of dnatco.js switches**, with a few switches managed or disabled (see
  [Command-line switches](#command-line-switches)).

For the underlying tool's own documentation, see [standalone_README.md](https://github.com/cernylab/dnatco/blob/new-style/standalone_README.md).

Prerequisites
---

- **[Nextflow](https://www.nextflow.io)** `>= 24.0` (needs a POSIX shell; on Windows run it
  under WSL2).
- **A container engine**: Docker, Podman, or Apple `container` (Nextflow ≥ 26.04 on Apple
  silicon) — see [Container engine](#container-engine).
- **Network access on the first run** to download the dnatco standalone tool and the
  `node:22` image (see [Network control](#network-control) for offline use).

You do **not** need Node.js, `npm`, or the dnatco sources on the host — everything runs in
the container.

Quick start
---

```bash
# single structure
nextflow run cernylab/dnatco-nf --input /path/to/structure.cif

# many structures (quote the glob so the shell doesn't expand it)
nextflow run cernylab/dnatco-nf --input '/data/*.cif.gz'
```

Accepted input formats: `.cif` and `.cif.gz`. Outputs are written next to each input file.

Show the underlying tool's full switch list and exit:

```bash
nextflow run cernylab/dnatco-nf --help
```

Outputs
---

For each input structure, outputs are named `<structure>_<outpref>_*` and published to the
input file's directory. `<structure>` is the input file's base name, which keeps names unique
across a multi-file glob; `--outpref` (default `dnatco`) customizes only the trailing tag.

By default the pipeline enables two dnatco.js outputs:

- `--extendedCIF` → `<structure>_dnatco_extended.cif` (mmCIF with DNATCO categories)
- `--anglesLengthsByResidueJson` → `<structure>_dnatco_angles_lengths_by_residue.json`

Any other dnatco.js output switch can be added on the command line (see below).

Command-line switches
---

The pipeline owns a few switches; everything else is forwarded to `dnatco.js` verbatim.

### Pipeline switches

| Switch | Default | Meaning |
|---|---|---|
| `--input` (alias `--coords`) | — | Path or glob of coordinate file(s); `.cif` / `.cif.gz`. Required (unless `--help`/`--version`). |
| `--outpref` | `dnatco` | Output filename tag: outputs are `<structure>_<outpref>_*`. |
| `--report` | off | Generate the PDF validation report. Needs the native `canvas` module, which the pipeline prepares automatically (see [The PDF report and canvas](#the-pdf-report-and-canvas)). |
| `--containerEngine` | `docker` | Container engine: `docker`, `podman`, or `container` (Apple container; Nextflow ≥ 26.04 on Apple silicon). See [Container engine](#container-engine). |
| `--offline` | off | Disable all pipeline-initiated network operations. |
| `--updateDnatco` | off | Re-download the latest dnatco standalone into `bin/`. |
| `--help` / `--version` | off | Print dnatco.js help/version and exit, ignoring all other switches. `--help` takes precedence. |

### Forwarded dnatco.js switches

Any `dnatco.js` switch not listed as disabled below is passed straight through, for example:

```bash
nextflow run cernylab/dnatco-nf --input structure.cif --ntcJson --reportText
nextflow run cernylab/dnatco-nf --input structure.cif --restraintsRmsd 0.4
```

A bare flag (e.g. `--ntcJson`) becomes `--ntcJson`; a switch with a value
(e.g. `--restraintsRmsd 0.4`) is forwarded as-is. To list every available dnatco.js switch,
run with `--help`. Notable ones include `--reportText`, `--busterRestraints`,
`--refmacRestraints`, `--cootRestraints`, `--phenixRestraints`, `--ntcCsv` / `--ntcJson`,
`--ntcFullCsv` / `--ntcFullJson`, `--anglesLengthsBy{Compound,Residue}{Csv,Json}`, and
`--rsccRmsdPlots`.

### Disabled / managed switches

These are **not** forwarded to `dnatco.js`. If you pass one, the pipeline warns that the
supplied value is ignored.

| Switch | Why it's disabled |
|---|---|
| `--coords` | The pipeline provides coordinates via `--input`; `--coords` is accepted only as an alias for it. |
| `--prefix` | The pipeline derives the output prefix from the input name and `--outpref`. Allowing a fixed `--prefix` would collide across a multi-file glob, so it is owned by the pipeline. |
| `--outputDir` | The pipeline always writes into the task/publish directory so outputs land next to each input. |
| `--reflns` | **Not supported.** RSCC / density-correlation requires external programs (e.g. Phenix) to compute the density correlations, which are not available in the container. The supplied reflections file is ignored. |

Because `--reflns` is unavailable, the density-correlation features that depend on it
(e.g. `--rsccRmsdPlots` RSCC values) cannot be computed here.

Container engine
---

Select the engine with `--containerEngine` (default `docker`). Docker, Podman, and Apple
`container` are all driven natively by Nextflow:

```bash
nextflow run cernylab/dnatco-nf --input structure.cif --containerEngine podman
```

Notes:

- **Docker** — on Linux, containers run as the invoking user (`-u $(id -u):$(id -g)`) with
  SELinux relabeling of bind mounts, so outputs are owned by you. On macOS/Windows (Docker
  Desktop) those options are dropped, since the file-sharing layer maps ownership itself.
- **Podman** — rootless Podman already maps the container user to your host user, so the
  pipeline does **not** pass `-u` (forcing it would make outputs owned by an unusable subuid).
- **Apple `container`** — `--containerEngine container` runs each task in its own lightweight
  VM via Nextflow's native `appleContainer` support. Requires **Nextflow ≥ 26.04 on Apple
  silicon** (M1 or newer). Start the service first:

  ```bash
  container system start
  nextflow run /path/to/dnatco-nf --input structure.cif --containerEngine container
  ```

  `node:22` is multi-arch, so the arm64 image runs natively — no Rosetta or platform override
  is needed.

docker (Apple `container` wrapper — fallback)
---

> With Nextflow ≥ 26.04 on Apple silicon, prefer the native `--containerEngine container`
> above; this wrapper is a **fallback** for older Nextflow (no `appleContainer` support).

The repository ships a [`docker`](docker) shim script that lets Nextflow drive **Apple's
`container`** engine by masquerading as `docker`.

**Why it's needed (without native support).** Nextflow builds the container command itself and
calls the literal `docker` binary; it cannot be told to call a differently-named engine, and
it injects options (such as `--cpu-shares`, derived from the task `cpus` directive) that
`container` rejects. The wrapper sits in front of `container`, drops the incompatible options
(and their values), and forwards the rest — so Nextflow's `docker run …` becomes a valid
`container run …`. Keep `--containerEngine docker` (the default) when using the wrapper, since
Nextflow must emit `docker` commands for the shim to intercept.

**Usage.** The wrapper only works if its directory is **ahead of the real `docker` on
`PATH`** *before* `nextflow run` starts — Nextflow resolves `docker` from the launch
environment and a shipped script cannot self-activate:

```bash
export PATH="/path/to/dnatco-nf:$PATH"   # directory containing this 'docker' shim
nextflow run /path/to/dnatco-nf --input structure.cif
```

This requires a local checkout (it does not apply to `nextflow run cernylab/dnatco-nf`, which
pulls the pipeline after the engine is first resolved).

**Extending it.** The shim drops a denylist of options at the top of the file
(`drop_with_value` and `drop_flag`). If `container` rejects a further option, add it to the
appropriate list — `--opt value` style goes in `drop_with_value`, bare flags in `drop_flag`.

The PDF report and canvas
---

The PDF report (`--report`) requires the native `canvas` module. The copy bundled in the
dnatco standalone is prebuilt for amd64 Linux and can fail to load under `node:22` on other
platforms (e.g. arm / Apple silicon, macOS). To be safe everywhere, the pipeline installs a
matching `canvas` version into a writable `.canvas/` cache and bind-mounts it into the
container at run time. If a working `canvas` cannot be prepared on your platform, the run
continues **without** the PDF (with a warning) rather than failing — the other outputs are
still produced.

Preparing canvas needs the network, so under `--offline` the PDF is skipped unless a prepared
`.canvas/` cache already exists.

Network control
---

On the first run (and whenever `bin/` is missing) the pipeline downloads the latest dnatco
standalone release from GitHub. The `node:22` image is pulled by the container engine as
usual.

- **`--updateDnatco`** — re-download the latest dnatco standalone into `bin/`, replacing the
  local copy. Without it, an already-installed `bin/` is reused; online runs print a notice
  when a newer release tag is available. Ignored under `--offline`.
- **`--offline`** — disable **all** pipeline-initiated network operations: the GitHub release
  check/download and the `npm` canvas install for `--report`. This requires the needed pieces
  to already be present: a populated `bin/`, the `node:22` image pulled locally, and (for
  `--report`) a prepared `.canvas/` cache. Otherwise those steps error or are skipped.

> Note: `--offline` (two dashes) is the **pipeline** option above. Nextflow also has its own
> `-offline` (one dash) core option, which only suppresses Nextflow's update checks — they are
> not the same thing.

Updating
---

There are two independent things you may want to update — the **pipeline** and the bundled
**dnatco tool** — and they use different mechanisms.

### The pipeline (dnatco-nf)

When you run `nextflow run cernylab/dnatco-nf`, Nextflow caches the project locally and reuses
that copy on later runs — it does **not** auto-update. To get a newer remote version:

```bash
# update the cached pipeline to the latest commit on the default branch
nextflow pull cernylab/dnatco-nf

# or pull-then-run in one step
nextflow run -latest cernylab/dnatco-nf --input structure.cif
```

Related commands:

- `nextflow info cernylab/dnatco-nf` — show the local revision and the available remote
  revisions/tags.
- `nextflow pull cernylab/dnatco-nf -r v1.0.0` (or `-r <branch>`) — pin a specific tag/branch.
- `nextflow drop cernylab/dnatco-nf` — remove the cached copy (a fresh clone is fetched on the
  next run).

### The dnatco tool (bin/)

The dnatco standalone tool that runs inside the container is separate from the pipeline. When a
newer release is available, an online run prints a notice; upgrade the local `bin/` with:

```bash
nextflow run cernylab/dnatco-nf --input structure.cif --updateDnatco
```

See [Network control](#network-control) for details.

Citation and License
---

If you use this software in scientific or academic work, you must cite the paper(s) listed in
the `CITATION.txt` file of the [dnatco repository](https://github.com/cernylab/dnatco). The
DNATCO standalone tool is distributed under the terms in its `LICENSE.txt` and
`assets/LICENSE.txt`. See [standalone_README.md](https://github.com/cernylab/dnatco/blob/new-style/standalone_README.md) for details.
