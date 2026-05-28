process DNATCO_CLASSIFY {
    tag "$cif.simpleName"
    container 'node:22'
    containerOptions "--volume ${params.dnatco_bin}:/opt/dnatco/bin:ro"
    stageInMode 'copy'

    input:
    tuple val(outdir), path(cif)

    output:
    tuple val(outdir), path("${cif.simpleName}_dnatco_extended.cif"),                   emit: extended_cif
    tuple val(outdir), path("${cif.simpleName}_dnatco_angles_lengths_by_residue.json"), emit: naval_json, optional: true

    script:
    def prefix    = "${cif.simpleName}_dnatco"
    def coordsCmd = cif.name.endsWith('.gz') ? "gunzip -c \$(pwd)/${cif} > \$(pwd)/${cif.baseName}" : ""
    def coordsArg = "\$(pwd)/" + (cif.name.endsWith('.gz') ? cif.baseName : cif.name)
    """
    ${coordsCmd}
    node /opt/dnatco/bin/dnatco.js \\
        --outputDir \$(pwd) \\
        --coords ${coordsArg} \\
        --prefix ${prefix} \\
        --extendedCIF \\
        --anglesLengthsByResidueJson
    """
}
