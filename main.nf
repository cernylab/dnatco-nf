#!/usr/bin/env nextflow

include { DNATCO_CLASSIFY } from './modules/dnatco_classify'

def ensureDnatco() {
    if (new File("${projectDir}/bin/dnatco.js").exists()) return

    log.info "dnatco standalone not found — fetching latest release from GitHub..."

    def conn = new URL("https://api.github.com/repos/cernylab/dnatco/releases/latest").openConnection()
    conn.setRequestProperty("Accept", "application/vnd.github.v3+json")
    conn.setRequestProperty("User-Agent", "nextflow-dnatco-pipeline")
    def json = new groovy.json.JsonSlurper().parse(conn.inputStream)
    def asset = json.assets.find { it.name.endsWith("_standalone.zip") }
    if (!asset) throw new Exception("No _standalone.zip asset found in latest GitHub release")

    log.info "Downloading ${asset.name} ..."
    def cmd = """
        set -euo pipefail
        TMP=\$(mktemp -d)
        trap "rm -rf \$TMP" EXIT
        curl -L --progress-bar -o "\$TMP/${asset.name}" "${asset.browser_download_url}"
        unzip -q "\$TMP/${asset.name}" -d "\$TMP/x"
        rm -rf "${projectDir}/bin"
        mv "\$TMP/x/dnatco/bin" "${projectDir}/"
    """.stripIndent()

    def proc = ["bash", "-c", cmd].execute()
    proc.consumeProcessOutputStream(System.out)
    proc.consumeProcessErrorStream(System.err)
    proc.waitFor()
    if (proc.exitValue() != 0) throw new Exception("Failed to install dnatco standalone tool")

    log.info "dnatco installed to ${projectDir}/bin"
}

workflow {
    main:
    if (!params.input) {
        error """
        ERROR: --input is required

        Usage:
          nextflow run main.nf --input /path/to/structure.cif
          nextflow run main.nf --input '/data/*.cif.gz'

        Accepted formats: .cif, .cif.gz
        """.stripIndent()
    }

    ensureDnatco()

    channel
        .fromPath(params.input, checkIfExists: true)
        .map { cif ->
            if (!cif.name.endsWith('.cif') && !cif.name.endsWith('.cif.gz')) {
                error "Input must be a .cif or .cif.gz file: ${cif}"
            }
            tuple(cif.parent, cif)
        }
        | DNATCO_CLASSIFY

    publish:
    extended_cif = DNATCO_CLASSIFY.out.extended_cif
    naval_json   = DNATCO_CLASSIFY.out.naval_json
}

output {
    extended_cif {
        path { outdir, _file -> outdir.toString() }
        mode 'copy'
    }
    naval_json {
        path { outdir, _file -> outdir.toString() }
        mode 'copy'
    }
}
