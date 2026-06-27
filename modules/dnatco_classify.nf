// Informational switches (--help, --version): run dnatco.js with that switch
// only and echo its output to the console. No coordinates are processed.
process DNATCO_INFO {
    container 'node:22'
    containerOptions "--volume ${params.dnatco_bin}:/opt/dnatco/bin:ro"
    debug true

    input:
    val flag

    script:
    """
    node /opt/dnatco/bin/dnatco.js --${flag}
    """
}

process DNATCO_CLASSIFY {
    tag "$cif.simpleName"
    container 'node:22'
    // Mount the dnatco bin read-only. For --report, canvasMount is the host path to a
    // working canvas install, bind-mounted over bin/node_modules so dnatco.js loads it
    // (the bundled canvas fails to load under node:22); empty means no --report.
    containerOptions {
        canvasMount
            ? "--volume ${params.dnatco_bin}:/opt/dnatco/bin:ro --volume ${canvasMount}:/opt/dnatco/bin/node_modules:ro"
            : "--volume ${params.dnatco_bin}:/opt/dnatco/bin:ro"
    }
    stageInMode 'copy'

    input:
    tuple val(outdir), path(cif)
    val canvasMount

    output:
    tuple val(outdir), path("${cif.simpleName}_${params.outpref}_*"), emit: results, optional: true

    script:
    def prefix    = "${cif.simpleName}_${params.outpref}"
    def coordsCmd = cif.name.endsWith('.gz') ? "gunzip -c \$(pwd)/${cif} > \$(pwd)/${cif.baseName}" : ""
    def coordsArg = "\$(pwd)/" + (cif.name.endsWith('.gz') ? cif.baseName : cif.name)

    // The pipeline owns --coords/--prefix/--outputDir; --reflns is unsupported
    // (handled/warned in main.nf). --report is gated on canvas being available, so
    // main.nf decides it and passes it as withReport. Every other param is forwarded
    // to dnatco.js verbatim:  true -> "--key"   a value -> "--key value"   false/null -> skipped
    //
    // A bare flag on the command line (e.g. --ntcJson) reaches us as the *string*
    // "true", while config defaults (extendedCIF = true) are real booleans; treat
    // both alike so a switch never gets a spurious "true" value appended.
    def managed = ['input', 'coords', 'reflns', 'prefix', 'outputDir', 'outpref', 'dnatco_bin',
                   'help', 'version', 'report', 'updateDnatco', 'offline']
    def passThrough = params
        .findAll { k, v -> !(k in managed) && v != null && v != false && v != 'false' }
        .collect { k, v -> (v == true || v == 'true') ? "--${k}" : "--${k} ${v}" }

    def withReport = (canvasMount ? true : false)
    def argv = [
        "--outputDir \$(pwd)",
        "--coords ${coordsArg}",
        "--prefix ${prefix}",
    ] + passThrough + (withReport ? ['--report'] : [])

    """
    ${coordsCmd}
    node /opt/dnatco/bin/dnatco.js \\
        ${argv.join(' \\\n        ')}
    """
}
