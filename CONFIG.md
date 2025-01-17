# PAV Configuration Options

Additional PAV configuration options for `config.json` in the PAV run directory or command-line
(e.g. `--config config_file="..."`).

The configuration parameter the expected type are given in brackets after the
parameter name. For example, type `int` would expect to take a string representation of a number (e.g. "12") and
translate it to an integer.

Type `bool` is boolean (True/False) values and is not case sensitive:
* True: "true", "1", "yes", "t", and "y"
* False: "false", "0", "no", "f", and "n"
* Other values generate an error.

## Commonly-used configuration options

### Base PAV

* config_file [config.json; string]: The runtime configuration file. This option must be supplied to PAV as a
  command-line parameter to have an effect (PAV reads the config file when it starts). By default, PAV searches for
  `config.json` in the run directory (not the PAV install directory where `Snakefile` is found). Using this option is not
  recommended, but it could be used to run different profiles (e.g. a different number of alignment threads). Changing
  some options after PAV has partially run, such as numbers of batches (see below) may cause variant call dropout
  or failures. 
* env_source [setenv.sh; string]: Source this file before running shell commands. If this file is present, it is sourced by
  prepending to all "shell" directives in Snakemake by calling: `shell.prefix('set -euo pipefail; source setenv.sh; ')`.
  Note that all shell commands evoke BASH strict mode regardless of the `setenv.sh`
  (See http://redsymbol.net/articles/unofficial-bash-strict-mode/).
* assembly_table [assemblies.tsv; string]: Assembly table file name (see "Assembly Input").
* reference [NA; string]: Location of the reference FASTA file, which may be uncompressed or gzip compressed. This
  parameter is required for all PAV runs.

### Alignments

* map_threads [12; int]: Number of threads the aligner will use.
* chrom_cluster [False; bool]: Use only if contigs are clustered by chromosome and if everything before the first "_" is
  the cluster name (e.g. "chr1_tig00001"). This feature was develoed to incoroprate QC information from PGAS
  (Porubski 2020, https://doi.org/10.1126/science.abf7117; Ebert 2021, https://doi.org/10.1126/science.abf7117), which
  clusters contigs by chromosome and haplotype, although the chromosome name is not known during the assembly (it is
  reference-free). If this option is set, PAV will fill the "CLUSTER_MATCH" field (variant call BED file). Each
  variant is called from a contig, and each contig is assinged a cluster. The cluster is assigned to a reference
  chromosome if 85% of the cluster maps to that single chromosome (not counting alignments less than 1 kbp in
  reference space). If the cluster is assigned to a chromosome, then a True/False value is given to this field if the
  chromosome and cluster match. If This feature is disabled (default) or the cluster was not assigned, the
  "CLUSTER_MATCH" field for the variant call will be empty (NA).
* min_trim_tig_len [1000, int]: Ignore contig alignments shorter than this size. This is the number of reference bases
  the contig covers.
* aligner [minimap2; string]: PAV supports minimap2 (aligner: minimap2) and LRA (aligner: lra). LRA is under development
  with the Chaisson lab (USC).

## Inversions

* inv_region_limit [1200000; int]: When scanning for inversions, the region is expanded until an inversion flanked
  by clean reference sequence is found. Expansion stops when a full inversion is found, no evidence of an inversion
  is seen in the region, or expansion hits this limit (number of reference bases covered).

### Large inversions

These inversion calls break the alignment into mulitple alignment records. PAV will first try to resolve these
through its k-mer density 

* inv_k_size [31; int]: Use k-mers of this size when resolving inversion breakpoints. Contig k-mers are assigned to
  a reference state (FWD, REV, FWD+REV, NA) by matching k-mers of this size to reference k-mer sets over the
  same region.
* inv_threads_lg [12; int]: Like `inv_threads`, but for large (alignment-truncating) inversion events.
* lg_batch_count [10; int]: Run large variant detection (variants truncating alignments) in this many batches and
  run each batch as one job. Improves the speed of large inversion detection in a cluster environment.

### Small inversions

Small inversions typically do not cause the aligner to break the contig into multiple records. Instead, it aligns
through the inversion leaving signatures of variation behind, but no inversion call. PAV recognizes these
signatures, such as SV insertions and deletions in close proximity with the same size and resolves the
inversion event. When an inversion is found, the false variants from those signatures are replaced with the
inversion call.

Parameters controlling inversion detection for small inversions:

* inv_threads [4; int]: Scan for inversions using this many simultaneous threads to compute smoothed density
  plots for k-mer states (for breakpoint and structure resolution). This parameter is specifically for resolving
  inversions within aligned contigs (i.e. did not break contig into multiple alignment records).
* inv_min_expand [1; int]: When searching for inversions, expand the search window at least this many times before
  giving up on a region. May be used to increase sensitivity for some inversions, but increasing this
  parameter penalizes performance heavily trying to resolve complex loci where there are no inversions.


### Inversion signatures

Signatures of small inversions include:
1. Matched SV insertions and deletions in close proximity with the same size (i.e. insertion matched with deletion).
1. Matched indel insertions and deletionsin close proximityd with the same size.
1. Clusters of SNVs.
1. Clusters of indels.

* inv_sig_filter [svindel; string]: Determine which inversion signature patterns PAV should try to resolve into an
  inversion call. See the four recognized signatures above.
    * single_cluster: Accept signatures from only clustered SNVs or clustered indels. This will cause PAV to search
      sites and maximize sensitivity for small inversions. There is a steep performance cost, and possibly a
      sharp increase in false-positive inversions as well. Use this parameter with caution and purpose.
    * svindel: Accept signatures with matched SVs or matched indels.
    * sv: Only accept signatures with matched SVs.
* inv_sig_merge_flank [500; int]: When searching for clustered SNVs or indels, cluster variants within this many bp.
* inv_sig_batch_count [60; int]: Batch signature regions into this many batches for the caller and distribute
  each batch as one job. Improves cluster parallelization, but has no performance effect for
  non-distributed jobs.
* inv_sig_insdel_cluster_flank [2; float]: For each insertion, multiply the SV length by this value and
  search for a matching SV deletion.
* inv_sig_insdel_merge_flank [2000; int]: Merge clusters within this distance.
* inv_sig_cluster_svlen_min [4; int]: Discard indels less than this size when searching for clustered signatures.
* inv_sig_cluster_win [200; int]: Cluster variants within this many bases
* inv_sig_cluster_win_min [500; int]: Clustered window must reach this size (first clustered variant to last
  clustered variant).
* inv_sig_cluster_snv_min [20; int]: Minimum number if SNVs in a window to be considered a SNV-clustered site.
* inv_sig_cluster_indel_min [10; int]: Minimum number of indels in a window to be considered an indel-clustered
  site.

### Density resolution parameters

In a region that is being scanned for an inversion, PAV knows the reference locus, the matching contig locus,
and the reference orientation (i.e. if the contig was reverse complemented when it was mapped).

PAV first extracts a list of k-mers from the scanned contig region. Over the matching reference region, it gets
a set of k-mers that match the contig k-mers and a set of k-mers that match the reverse-complemented contig
k-mers.

Each contig k-mer is then assigned a state:

* FWD: Contig k-mer matches a reference k-mer in the same orientation.
* REV: Contig k-mer matches a reference k-mer if it is reverse-complemented.
* FWDREV: Contig k-mer and it's reverse complement both match reference k-mers.
  * Common inside inverted repeats flanking NAHR-driven inversions.
* NA: K-mer does not match a reference k-mer in the region.

PAV then removes any k-mers with an NA state and re-numbers them contiguously. This allows the following steps to
be less biased by variation that emerged within the inversion since the inversion event or contcurrently with
the inversion event. For example, an MEI insertion in the inversion will not cause inversion detection to fail. PAV
stores the original k-mer coordinates, which are restored later.

PAV then generates a density function for each state (FWD, REV, FWDREV) and applies it to the contig k-mers.
Density is computed and scaled between 0 and 1 (max value for any k-mer is 1). Using the smoothed density, PAV
determines the internal structure of the inversion by setting breakpoins where the maximum state changes. For
example, a typical inversion flanked by inverted repeats will traverse through states
(FWD > FWDREV > REV > FWDREV > FWD). If PAV sees this pattern, it sets outer breakpoints at the FWD/FWDREV
transition and inner breakpoints at the FWDREV/REV transitions. Note that some inversions generated by other
mechanisms will not have FWDREV states, and the inner/outer breakpoints will be set to the same location where
FWD transitions to either FWDREV or REV on each side. PAV requires max states tho be FWD on each side and
REV occuring at least once inside the locus to call an inversion. Very complex patterns are sometimes seen
inside, such as multiple FWDREV/REV transitions (common in MEI-dense loci).

Once PAV sees the necessary state transitions, it moves back to the original contig coordinates (recall that NA
states were removed for density computations), annotates the inner and outer breakpoints in both reference and
contig space, and emits the inversion call.

Because computing density values is very compute heavy, PAV implements an interpolation scheme to avoid computing
densities for each location in the contig. By default, it computes every 20th k-mer density and interpolates
the values between them. If the maximum state changes or if there is a significant change in the density within
the interpolated region, the actual density is computed for each k-mer in the window.

A parameter, `srs_list` is a list of lists in the JSON configuration file. It can be used to allow PAV to
search for very large inversions while fine-tuning the interpolation distance. Generally, larger inversions can
tolerate more interpolation, however, it is possible that small changes in structure would be missed. We have
observed little gains in our own work trying to tune this way, but it can be helpful if the reference and
sample are significantly diverged.

Each element in `srs_list` is a pair of region length and interpolation distance. See example below. 

* srs_list [None; list of lists]: Set a dynamic smoothing limits based on the size of the region being scanned.
  Larger regions with interpolate over larger distances.


    "srs_list": [
        [0, 20],
        [20000, 40],
        [60000, 80],
        [100000, 120],
        [500000, 400],
        [800000, 600]
    ],

In this example, a region up to 20 kbp will compute denisty on every 20th k-mer, a region from 20 kbp up to 60 kbp
will compute every 40th k-mer, and so on. If the first record does not start with 0, then it is automatically
extended down to 0 (e.g. if the first element is "[100, 20]", it is the same as "[0, 20]"). The last window size
is extended up to infinity (e.g. a 1 Mbp inversion in the example above would compute density for every 600th k-mer).

Recall that PAV will fill actual density values if it sees a state change or a large change in state, so large values
for the second parameter will give diminishing returns.

## Summary of all parameters

### Alignment

* aligner [minimap2]
* min_trim_tig_len [1000]
* redundant_callset [False]: Allow multiple haplotypes in one assembly. This option turns off trimming reference bases
  from alignments unless two alignment records are from the same contig. Can increase false calls, especially for small
  variants, but should not eliminate haplotypic variation in an assembly that is not separated into two FASTA files.
* chrom_cluster [False]
* sample_delimiter [_]: For extracting sample from assembly name ("{sample}" wildcard in input path patterns). May be one of "_", ".", "-", "+", "#".
* minimap2_params [-x asm20 -m 10000 -z 10000,50 -r 50000 --end-bonus=100 -O 5,56 -E 4,1 -B 5]: Alignment parameters used to run minimap2

### Call

* merge_ins [param merge_svindel]: Override default merging parameters for SV/indel insertions (INS).
* merge_del [param merge_svindel]: Override default merging parameters for SV/indel deletions (DEL).
* merge_inv [param merge_svindel]: Override default merging parameters for SV/indel inversions (INV). 
* merge_svindel [nr::exact:ro(0.5):szro(0.5,200):match]: Override default merging parameters for INS, DEL, INV
* merge_snv [nrsnv:exact]: Override default merging parameters for SNVs
* merge_threads [12]
* min_inv [300]
* max_inv [2000000]
* inv_min_svlen [300]
* inv_inner [False]: If True, allow small variant calls inside inversions. Variants will be in reference orientation, but some could be the result of poor alignments around inversion breakpoints.

* inv_min [300]
* inv_max [2000000]

### Call - INV
* inv_k_size [31]
* inv_threads [4]
* inv_region_limit [None]
* inv_min_expand [None]
* inv_sig_merge_flank [500]
* inv_sig_batch_count [BATCH_COUNT_DEFAULT]
* inv_sig_filter [svindel]
* inv_sig_insdel_cluster_flank [2]
* inv_sig_insdel_merge_flank [2000]
* inv_sig_cluster_svlen_min [4]
* inv_sig_cluster_win [200]
* inv_sig_cluster_win_min [500]
* inv_sig_cluster_snv_min [20]
* inv_sig_cluster_indel_min [10]

### Call - Large SV
* inv_k_size [31]
* inv_threads_lg [12]
* inv_region_limit [None]
* lg_batch_count [10]

