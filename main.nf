#!/usr/bin/env nextflow

include { DNATCO_CLASSIFY; DNATCO_INFO } from './modules/dnatco_classify'

// True on Linux hosts. Gates Linux-only container options (SELinux relabeling, host-uid
// mapping) that are meaningless or rejected elsewhere: on macOS/Windows Docker Desktop the
// file-sharing layer maps ownership itself, and engines like Apple 'container' reject the
// SELinux flag.
def isLinuxHost() {
    System.getProperty('os.name')?.toLowerCase()?.contains('linux')
}

// Host-side run options for our *manual* engine calls (the canvas helpers below), matching
// what nextflow.config applies to Nextflow-managed tasks. Empty off Linux. On Linux docker
// gets '--user' so outputs are owned by the host user; rootless podman must NOT set it
// (container-root already maps to the host user, and forcing --user yields outputs owned by
// an unusable subuid), so it gets only the SELinux relabel.
def hostEngineOpts(String engine, String uidgid) {
    if (!isLinuxHost()) return []
    return engine == 'podman'
        ? ['--security-opt', 'label=disable']
        : ['--security-opt', 'label=disable', '--user', uidgid]
}

// Is the engine installed and its daemon responding? 'info' is the canonical check, but some
// docker-CLI-compatible engines (e.g. Apple 'container') have no 'info' subcommand; fall back
// to an image listing, which also requires a running daemon.
def engineProbe(List<String> args) {
    try {
        def p = args.execute()
        p.consumeProcessOutput()          // drain stdout/stderr so the process can't block
        p.waitFor()
        return p.exitValue() == 0
    }
    catch (IOException e) {
        return false                      // binary not on PATH, or probe unsupported
    }
}

def engineResponds(String engine) {
    return engineProbe([engine, 'info']) || engineProbe([engine, 'image', 'ls'])
}

// Is an image already present locally (so it won't need pulling)?
def imageAvailable(String engine, String image) {
    try {
        def p = [engine, "image", "inspect", image].execute()
        p.consumeProcessOutput()
        p.waitFor()
        return p.exitValue() == 0
    }
    catch (IOException e) {
        return false
    }
}

def ensureEngine(String engine, boolean offline) {
    // dnatco.js only ever runs inside the 'node:22' container, so a working container engine
    // is required before we attempt anything (including pulling dnatco).
    if (!engineResponds(engine)) {
        error """
        ERROR: the '${engine}' container engine is not available.

        This pipeline runs dnatco.js inside the 'node:22' container, so a working ${engine}
        installation with a running daemon is required.

        Verify with:  ${engine} info
        """.stripIndent()
    }

    // Every container step uses 'node:22'. Offline we can't pull it, so fail early with a
    // clear message rather than letting each task fail on an image pull.
    if (offline && !imageAvailable(engine, 'node:22')) {
        error """
        ERROR: the 'node:22' image is not available locally and --offline is set.

        Pull it once while online ('${engine} pull node:22'), or re-run without --offline.
        """.stripIndent()
    }
}

// Fetch the latest release metadata from GitHub. Best-effort: returns null on any failure
// (offline, DNS, rate-limited, ...) so an update check never breaks a run.
def fetchLatestRelease() {
    try {
        def conn = new URL("https://api.github.com/repos/cernylab/dnatco/releases/latest").openConnection()
        conn.setRequestProperty("Accept", "application/vnd.github.v3+json")
        conn.setRequestProperty("User-Agent", "nextflow-dnatco-pipeline")
        conn.connectTimeout = 5000
        conn.readTimeout = 5000
        return new groovy.json.JsonSlurper().parse(conn.inputStream)
    }
    catch (Exception e) {
        return null
    }
}

def ensureDnatco(boolean offline, boolean force) {
    def bin       = "${projectDir}/bin"
    def relFile   = new File("${bin}/.release")
    def installed = new File("${bin}/dnatco.js").exists()

    // Already installed and not forcing an update: keep the local copy. When online, do a
    // best-effort check and tell the user (without blocking) if a newer release exists.
    if (installed && !force) {
        if (!offline) {
            def latest    = fetchLatestRelease()
            def latestTag = latest?.tag_name
            def localTag  = relFile.exists() ? relFile.text.trim() : null
            if (latestTag && localTag && latestTag != localTag) {
                log.warn "A newer dnatco release is available: ${latestTag} (installed: ${localTag}). " +
                         "Re-run with --updateDnatco to upgrade."
            }
        }
        return
    }

    // From here we'd need to download (first install, or forced update) — impossible offline.
    if (offline) {
        if (installed) {
            log.warn "--updateDnatco ignored because --offline is set; using the existing local copy."
            return
        }
        error """
        ERROR: dnatco standalone is not present in ${bin} and --offline is set, so it cannot be downloaded.

        Re-run without --offline to fetch it from GitHub, or provide a populated bin/ directory.
        """.stripIndent()
    }

    log.info installed
        ? "Updating dnatco standalone (--updateDnatco): fetching latest release from GitHub..."
        : "dnatco standalone not found — fetching latest release from GitHub..."

    def json = fetchLatestRelease()
    if (!json) throw new Exception("Could not fetch the latest dnatco release from GitHub")
    def asset = json.assets.find { a -> a.name.endsWith("_standalone.zip") }
    if (!asset) throw new Exception("No _standalone.zip asset found in latest GitHub release")

    log.info "Downloading ${asset.name} (${json.tag_name}) ..."
    def cmd = """
        set -euo pipefail
        TMP=\$(mktemp -d)
        trap "rm -rf \$TMP" EXIT
        curl -L --progress-bar -o "\$TMP/${asset.name}" "${asset.browser_download_url}"
        unzip -q "\$TMP/${asset.name}" -d "\$TMP/x"
        rm -rf "${bin}"
        mv "\$TMP/x/dnatco/bin" "${projectDir}/"
    """.stripIndent()

    def proc = ["bash", "-c", cmd].execute()
    proc.consumeProcessOutputStream(System.out)
    proc.consumeProcessErrorStream(System.err)
    proc.waitFor()
    if (proc.exitValue() != 0) throw new Exception("Failed to install dnatco standalone tool")

    // Record the installed release tag so later runs can detect newer releases.
    new File("${bin}/.release").text = json.tag_name ?: ''
    log.info "dnatco ${json.tag_name ?: ''} installed to ${bin}"
}

// Does the canvas installed in the cache dir actually load under node:22?
// (hostEngineOpts mirrors the engine's run options per-platform so SELinux doesn't block the
// bind mount on Linux; these calls run the engine directly, not via Nextflow's container handling.)
def canvasCacheLoads(String engine, String cache, String uidgid) {
    def cmd = [engine, "run", "--rm"] + hostEngineOpts(engine, uidgid) +
              ["-e", "HOME=/tmp", "-v", "${cache}:/c:ro", "node:22",
               "node", "-e", "require('/c/node_modules/canvas')"]
    def p = cmd.execute()
    p.consumeProcessOutput()
    p.waitFor()
    return p.exitValue() == 0
}

// Provide a working native 'canvas' (needed for --report's PDF). The canvas bundled in the
// dnatco standalone is built for a different environment and fails to load under node:22 on
// both x64 and arm. Rather than rewrite the bundled bin/ (often read-only / not writable by
// the container user — EACCES on shared or remote installs), install a matching canvas
// version into a writable cache dir we own; the runtime then bind-mounts it over
// bin/node_modules. Returns the host path to the cache's node_modules, or null if no working
// canvas could be produced — so the caller can carry on without the PDF instead of failing.
def ensureCanvas(String engine, boolean offline) {
    def bin    = "${projectDir}/bin"
    def cache  = "${projectDir}/.canvas"
    def uidgid = "${['id','-u'].execute().text.trim()}:${['id','-g'].execute().text.trim()}"

    // Match the version the bundle expects, for API compatibility.
    def version = new groovy.json.JsonSlurper()
        .parse(new File("${bin}/node_modules/canvas/package.json")).version

    // Reuse the cache if it already holds a loadable canvas of the right version.
    def cachedPkg = new File("${cache}/node_modules/canvas/package.json")
    def cachedVer = cachedPkg.exists() ? new groovy.json.JsonSlurper().parse(cachedPkg).version : null
    if (cachedVer == version && canvasCacheLoads(engine, cache, uidgid)) return "${cache}/node_modules"

    // Installing canvas needs the network; under --offline we can only use a prebuilt cache.
    if (offline) {
        log.warn "Cannot prepare 'canvas' for --report while --offline is set (npm install needs network)."
        return null
    }

    log.info "Preparing native canvas@${version} for --report in ${cache} ..."
    new File(cache).mkdirs()
    def install = ([engine, "run", "--rm"] + hostEngineOpts(engine, uidgid) +
                   ["-e", "HOME=/tmp", "-v", "${cache}:/c", "-w", "/c", "node:22",
                    "npm", "install", "--no-save", "--no-audit", "--no-fund", "canvas@${version}"]).execute()
    install.consumeProcessOutputStream(System.out)
    install.consumeProcessErrorStream(System.err)
    install.waitFor()

    if (install.exitValue() != 0 || !canvasCacheLoads(engine, cache, uidgid)) return null

    log.info "Native 'canvas' ready."
    return "${cache}/node_modules"
}

workflow {
    main:
    // Informational switches short-circuit everything else: run dnatco.js with
    // just that switch. --help takes precedence over --version.
    def infoFlag = params.help ? 'help' : (params.version ? 'version' : null)

    // Network control: --offline disables all pipeline-initiated network ops; --updateDnatco
    // forces a re-download of the dnatco standalone (ignored under --offline).
    def offline = (params.offline == true || params.offline == 'true')
    def force   = (params.updateDnatco == true || params.updateDnatco == 'true')

    // Container engine. docker and podman are both run by Nextflow natively (the engine is
    // selected in nextflow.config) and used directly by our manual engine calls below.
    def engine = params.containerEngine
    if (engine == 'container') {
        error """
        ERROR: --containerEngine 'container' (Apple container) is not supported yet.

        Nextflow has no native driver for Apple's 'container' engine, so the per-process
        containers cannot be run through it. Until that's wired up, use Docker/podman here,
        or put a 'docker'-named wrapper that forwards to 'container' first on your PATH
        before launching the pipeline.
        """.stripIndent()
    }
    if (!(engine in ['docker', 'podman'])) {
        error "ERROR: unsupported --containerEngine '${engine}'. Supported engines: docker, podman."
    }

    ensureEngine(engine, offline)
    ensureDnatco(offline, force)

    if (infoFlag) {
        if (infoFlag == 'help' && params.version) {
            log.warn "Both --help and --version given; running --help (--version ignored)."
        }
        log.warn "Running 'dnatco.js --${infoFlag}' only; all other switches and inputs are ignored."
        DNATCO_INFO(channel.of(infoFlag))
    }
    else {
        // '--input' is a synonym for dnatco.js' --coords.
        def coords = params.input ?: params.coords
        if (!coords) {
            error """
            ERROR: --input (alias --coords) is required

            Usage:
              nextflow run main.nf --input /path/to/structure.cif
              nextflow run main.nf --input '/data/*.cif.gz'

            Accepted formats: .cif, .cif.gz

            Any other dnatco.js switch is forwarded as-is, e.g.:
              nextflow run main.nf --input structure.cif --ntcJson --reportText
              nextflow run main.nf --input structure.cif --restraintsRmsd 0.4

            See all dnatco.js switches with:
              nextflow run main.nf --help
            """.stripIndent()
        }

        // dnatco.js switches the pipeline disables: either it sets them itself (so a user
        // value would be overwritten) or the feature isn't supported here. None are forwarded
        // to dnatco.js (see the 'managed' list in the DNATCO_CLASSIFY module). Each defaults
        // to null in nextflow.config, so a non-null value means the user passed it — warn for
        // each so an ignored switch never looks effective.
        def disabledSwitches = [
            prefix   : "the pipeline derives the output prefix from the input name and --outpref",
            outputDir: "the pipeline always writes outputs into the task/publish directory",
            reflns   : "RSCC / density correlation is not supported here (it needs external programs)",
        ]
        disabledSwitches.each { sw, why ->
            if (params[sw] != null) {
                log.warn "--${sw} is not passed to dnatco.js (${why}); the supplied value " +
                         "'${params[sw]}' is ignored."
            }
        }

        // --report needs the native 'canvas' module. Prepare a working one in a cache dir
        // (bind-mounted over bin/node_modules at runtime). If it can't be made to work on
        // this platform, skip the PDF (warn) rather than failing the whole run — the
        // remaining outputs are still produced. canvasMount = '' means "no --report".
        def canvasMount = ''
        if (params.report == true || params.report == 'true') {
            canvasMount = ensureCanvas(engine, offline) ?: ''
            if (!canvasMount) {
                log.warn "--report PDF will NOT be generated: a working 'canvas' module could not " +
                         "be prepared on this platform. Continuing with the other outputs."
            }
        }

        def inputs = channel
            .fromPath(coords, checkIfExists: true)
            .map { cif ->
                if (!cif.name.endsWith('.cif') && !cif.name.endsWith('.cif.gz')) {
                    error "Input must be a .cif or .cif.gz file: ${cif}"
                }
                tuple(cif.parent, cif)
            }

        DNATCO_CLASSIFY(inputs, canvasMount)
    }

    publish:
    results = infoFlag ? channel.empty() : DNATCO_CLASSIFY.out.results
}

output {
    results {
        path { outdir, _file -> outdir.toString() }
        mode 'copy'
    }
}
