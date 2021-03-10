"""
Process alignments and alignment tiling paths.
"""

#
# Definitions
#

def _align_map_cpu(wildcards, config):

    if 'map_threads' in config:
        try:
            return int(config['map_threads'])
        except ValueError as ex:
            raise ValueError('Config parameter "map_threads" is not an integer: {map_threads}'.format(**config))

    return 12


#
# Alignment generation and processing
#

# align_cut_tig_overlap
#
# Cut contig alignment overlaps
rule align_cut_tig_overlap:
    input:
        bed='results/{asm_name}/align/pre-cut/aligned_tig_{hap}.bed.gz',
        tig_fai='temp/{asm_name}/align/contigs_{hap}.fa.gz.fai'
    output:
        bed='results/{asm_name}/align/aligned_tig_{hap}.bed.gz'
    params:
        chrom_cluster=pavlib.util.as_bool(config.get('chrom_cluster', False)),  # Assembly was clustered by chromosome and first part of chromosome name before "_" is the cluster name.
        min_trim_tig_len=np.int32(config.get('min_trim_tig_len', 1000))  # Minimum aligned tig length
    run:

        min_trim_tig_len = params.min_trim_tig_len

        # Read uncut alignments
        df = pd.read_csv(input.bed, sep='\t')

        # Add fields for the number of bases that are removed from each end
        df['CUT_REF_L'] = 0
        df['CUT_REF_R'] = 0
        df['CUT_TIG_L'] = 0
        df['CUT_TIG_R'] = 0

        # Sort by contig alignment length
        df['QUERY_LEN'] = df['QUERY_END'] - df['QUERY_POS']
        df['SUB_LEN'] = df['END'] - df['POS']

        df.sort_values(['QUERY_ID', 'QUERY_LEN'], ascending=(True, False), inplace=True)

        df.reset_index(inplace=True, drop=True)

        # Find max cluster match for each chromosome
        if params.chrom_cluster:
            df['CLUSTER'] = df['QUERY_ID'].apply(lambda val: val.split('_')[0])
            max_cluster = {chrom: pavlib.align.get_max_cluster(df, chrom) for chrom in set(df['#CHROM'])}

            df['CLUSTER_MATCH'] = df.apply(lambda row: row['CLUSTER'] == max_cluster[row['#CHROM']], axis=1)
            df['CLUSTER_MATCH'] = df.apply(lambda row: row['CLUSTER_MATCH'] if max_cluster[row['#CHROM']] is not None else np.nan, axis=1)

        else:
            df['CLUSTER_MATCH'] = np.nan

        # Remove short alignments
        for index in df.index:
            if df.loc[index, 'QUERY_TIG_END'] - df.loc[index, 'QUERY_TIG_POS'] < min_trim_tig_len:
                df.loc[index, 'INDEX'] = -1

        # Resolve overlapping contig regions aligned (one contig region aligned more than once)
        iter_index_l = 0
        index_max = df.shape[0]

        while iter_index_l < index_max:
            iter_index_r = iter_index_l + 1

            while iter_index_r < index_max and df.loc[iter_index_l, 'QUERY_ID'] == df.loc[iter_index_r, 'QUERY_ID']:

                # Skip if one record was already removed
                if df.loc[iter_index_l, 'INDEX'] < 0 or df.loc[iter_index_r, 'INDEX'] < 0:
                    iter_index_r += 1
                    continue

                # Get indices ordered by contig placement
                if df.loc[iter_index_l, 'QUERY_TIG_POS'] <= df.loc[iter_index_r, 'QUERY_TIG_POS']:
                    index_l = iter_index_l
                    index_r = iter_index_r
                else:
                    index_l = iter_index_r
                    index_r = iter_index_l

                # Check for overlaps
                if df.loc[index_r, 'QUERY_TIG_POS'] < df.loc[index_l, 'QUERY_TIG_END']:
                    # Found overlapping records
                    # print('Tig Overlap: {}-{} ({}:{}-{},{} vs {}:{}-{},{}) [iter {}, {}]'.format(
                    #     df.loc[index_l, 'INDEX'], df.loc[index_r, 'INDEX'],
                    #     df.loc[index_l, 'QUERY_ID'], df.loc[index_l, 'QUERY_TIG_POS'], df.loc[index_l, 'QUERY_TIG_END'], ('-' if df.loc[index_l, 'REV'] else '+'),
                    #     df.loc[index_r, 'QUERY_ID'], df.loc[index_r, 'QUERY_TIG_POS'], df.loc[index_r, 'QUERY_TIG_END'], ('-' if df.loc[index_r, 'REV'] else '+'),
                    #     iter_index_l, iter_index_r
                    # ))

                    # Check for record fully contained within another
                    if df.loc[index_r, 'QUERY_TIG_END'] <= df.loc[index_l, 'QUERY_TIG_END']:
                        # print('\t* Fully contained')

                        df.loc[index_r, 'INDEX'] = -1

                    else:

                        record_l, record_r = pavlib.align.trim_alignments(
                            df.loc[index_l], df.loc[index_r], 'query',
                            rev_l=not df.loc[index_l, 'REV'],
                            rev_r=df.loc[index_r, 'REV']
                        )

                        if record_l is not None and record_r is not None:

                            # Modify if new aligned size is at least min_trim_tig_len, remove if shorter
                            if record_l['QUERY_TIG_END'] - record_l['QUERY_TIG_POS'] >= min_trim_tig_len:
                                df.loc[index_l] = record_l
                            else:
                                df.loc[index_l, 'INDEX'] = -1

                            if (record_r['QUERY_TIG_END'] - record_r['QUERY_TIG_POS']) >= min_trim_tig_len:
                                df.loc[index_r] = record_r
                            else:
                                df.loc[index_r, 'INDEX'] = -1

                        # print('\t* Trimmed')

                # Next r record
                iter_index_r += 1

            # Next l record
            iter_index_l += 1

        # Remove discarded records and re-sort

        df = df.loc[df['INDEX'] >= 0]

        df['QUERY_LEN'] = df['QUERY_END'] - df['QUERY_POS']

        df.sort_values(['#CHROM', 'QUERY_LEN'], ascending=(True, False), inplace=True)

        df.reset_index(inplace=True, drop=True)

        # Resolve overlapping contig alignments relative to the reference
        iter_index_l = 0
        index_max = df.shape[0]

        while iter_index_l < index_max:
            iter_index_r = iter_index_l + 1

            while (
                    iter_index_r < index_max and
                    df.loc[iter_index_l, '#CHROM'] == df.loc[iter_index_r, '#CHROM']
            ):

                # Skip if one record was already removed
                if df.loc[iter_index_l, 'INDEX'] < 0 or df.loc[iter_index_r, 'INDEX'] < 0:
                    iter_index_r += 1
                    continue

                # Get indices ordered by contig placement
                if df.loc[iter_index_l, 'POS'] <= df.loc[iter_index_r, 'POS']:
                    index_l = iter_index_l
                    index_r = iter_index_r
                else:
                    index_l = iter_index_r
                    index_r = iter_index_l

                # Check for overlaps
                if df.loc[index_r, 'POS'] < df.loc[index_l, 'END']:
                    # Found overlapping records
                    # print('Ref Overlap: {}-{} ({}:{}-{},{} vs {}:{}-{},{}) [iter {}, {}]'.format(
                    #     df.loc[index_l, 'INDEX'], df.loc[index_r, 'INDEX'],
                    #     df.loc[index_l, 'QUERY_ID'], df.loc[index_l, 'QUERY_TIG_POS'], df.loc[index_l, 'QUERY_TIG_END'], ('-' if df.loc[index_l, 'REV'] else '+'),
                    #     df.loc[index_r, 'QUERY_ID'], df.loc[index_r, 'QUERY_TIG_POS'], df.loc[index_r, 'QUERY_TIG_END'], ('-' if df.loc[index_r, 'REV'] else '+'),
                    #     iter_index_l, iter_index_r
                    # ))

                    # Check for record fully contained within another
                    if df.loc[index_r, 'END'] <= df.loc[index_l, 'END']:
                        # print('\t* Fully contained')

                        df.loc[index_r, 'INDEX'] = -1

                    else:

                        record_l, record_r = pavlib.align.trim_alignments(df.loc[index_l], df.loc[index_r], 'subject')

                        if record_l is not None and record_r is not None:

                            # Modify if new aligned size is at least min_trim_tig_len, remove if shorter
                            if record_l['QUERY_TIG_END'] - record_l['QUERY_TIG_POS'] >= min_trim_tig_len:
                                df.loc[index_l] = record_l
                            else:
                                df.loc[index_l, 'INDEX'] = -1

                            if (record_r['QUERY_TIG_END'] - record_r['QUERY_TIG_POS']) >= min_trim_tig_len:
                                df.loc[index_r] = record_r
                            else:
                                df.loc[index_r, 'INDEX'] = -1

                        # print('\t* Trimmed')

                # Next r record
                iter_index_r += 1

            # Next l record
            iter_index_l += 1


        # Clean and re-sort
        df = df.loc[df['INDEX'] >= 0]

        df = df.loc[(df['END'] - df['POS']) > 0]  # Should never occur, but don't allow 0-length records
        df = df.loc[(df['QUERY_END'] - df['QUERY_POS']) > 0]

        df.sort_values(['#CHROM', 'POS', 'END', 'QUERY_ID'], ascending=[True, True, False, True], inplace=True)

        del(df['QUERY_LEN'])
        del(df['SUB_LEN'])

        # Check sanity
        df_tig_fai = svpoplib.ref.get_df_fai(input.tig_fai)

        df.apply(pavlib.align.check_record, df_tig_fai=df_tig_fai, axis=1)

        # Write
        df.to_csv(output.bed, sep='\t', index=False, compression='gzip')


# align_get_read_bed
#
# Get alignment BED for one part (one aligned cell or split BAM) in one assembly.
rule align_get_read_bed:
    input:
        sam='temp/{asm_name}/align/pre-cut/aligned_tig_{hap}.sam.gz',
        tig_fai='temp/{asm_name}/align/contigs_{hap}.fa.gz.fai'
    output:
        bed='results/{asm_name}/align/pre-cut/aligned_tig_{hap}.bed.gz',
        align_head='results/{asm_name}/align/pre-cut/aligned_tig_{hap}.headers.gz'
    wildcard_constraints:
        hap='h(0|1|2)'
    run:

        # Write an empty file if SAM is emtpy
        if os.stat(input.sam).st_size == 0:

            pd.DataFrame(
                [],
                columns=[
                    '#CHROM', 'POS', 'END',
                    'INDEX',
                    'QUERY_ID', 'QUERY_POS', 'QUERY_END',
                    'QUERY_TIG_POS', 'QUERY_TIG_END',
                    'RG', 'AO',
                    'MAPQ',
                    'REV', 'FLAGS', 'HAP',
                    'CIGAR'
                ]
            ).to_csv(
                output.bed, sep='\t', index=False, compression='gzip'
            )

            with open(output.align_head, 'w') as out_file:
                pass

        # Read FAI
        df_tig_fai = svpoplib.ref.get_df_fai(input.tig_fai)
        df_tig_fai.index = df_tig_fai.index.astype(str)

        # Get records
        clip_l = 0
        clip_r = 0

        record_list = list()

        align_index = 0

        with pysam.AlignmentFile(input.sam, 'rb') as in_file:
            for record in in_file:

                # Skipped unmapped reads
                if record.is_unmapped:
                    continue

                # Get length for computing real tig positions for rev-complemented records
                tig_len = df_tig_fai[record.query_name]

                # Read tags
                tags = dict(record.get_tags())

                # Get clipping
                cigar_tuples = record.cigartuples

                l_index = 0 if cigar_tuples[0][0] != 5 else 1
                r_index = -1 if cigar_tuples[-1][0] != 5 else -2

                clip_l = cigar_tuples[l_index][1] if cigar_tuples[l_index][0] == 4 else 0
                clip_r = cigar_tuples[r_index][1] if cigar_tuples[r_index][0] == 4 else 0

                # Disallow alignment match (M) in CIGAR (requires =X for base match/mismatch)
                if 'M' in record.cigarstring:
                    raise RuntimeError((
                        'Found alignment match CIGAR operation (M) for record {} (Start = {}:{}): '
                        'Alignment requires CIGAR base-level match/mismatch (=X)'
                    ).format(record.query_name, record.reference_name, record.reference_start))

                # Save record
                record_list.append(pd.Series(
                    [
                        record.reference_name,
                        record.reference_start,
                        record.reference_end,

                        align_index,

                        record.query_name,
                        record.query_alignment_start,
                        record.query_alignment_end,

                        tig_len - record.query_alignment_end if record.is_reverse else record.query_alignment_start,
                        tig_len - record.query_alignment_start if record.is_reverse else record.query_alignment_end,

                        tags['RG'] if 'RG' in tags else 'NA',
                        tags['AO'] if 'AO' in tags else 'NA',

                        record.mapping_quality,

                        record.is_reverse,
                        '0x{:04x}'.format(record.flag),

                        wildcards.hap,
                        record.cigarstring
                    ],
                    index=[
                        '#CHROM', 'POS', 'END',
                        'INDEX',
                        'QUERY_ID', 'QUERY_POS', 'QUERY_END',
                        'QUERY_TIG_POS', 'QUERY_TIG_END',
                        'RG', 'AO',
                        'MAPQ',
                        'REV', 'FLAGS', 'HAP',
                        'CIGAR'
                    ]
                ))

                # Increment align_index
                align_index += 1

        # Merge records
        if len(record_list) > 0:
            df = pd.concat(record_list, axis=1).T
        else:
            df = pd.DataFrame(
                [],
                columns=[
                    '#CHROM', 'POS', 'END',
                    'INDEX',
                    'QUERY_ID', 'QUERY_POS', 'QUERY_END',
                    'QUERY_TIG_POS', 'QUERY_TIG_END',
                    'RG', 'AO',
                    'MAPQ',
                    'REV', 'FLAGS', 'HAP',
                    'CIGAR'
                ]
            )

        df.sort_values(['#CHROM', 'POS', 'END', 'QUERY_ID'], ascending=[True, True, False, True], inplace=True)

        # Check sanity
        df.apply(pavlib.align.check_record, df_tig_fai=df_tig_fai, axis=1)

        # Write SAM headers
        with gzip.open(input.sam, 'rt') as in_file:
            with gzip.open(output.align_head, 'wt') as out_file:

                line = next(in_file)

                while True:

                    if not line.strip():
                        continue

                    if not line.startswith('@'):
                        break

                    out_file.write(line)

                    try:
                        line = next(in_file)
                    except StopIteration:
                        break

        # Write
        df.to_csv(output.bed, sep='\t', index=False, compression='gzip')

# align_map
#
# Map contigs as SAM. Pull read information from the SAM before sorting and writing CRAM since tool tend to change
# "=X" to "M" in the CIGAR.
rule align_map:
    input:
        ref_fa='data/ref/ref.fa.gz',
        fa='temp/{asm_name}/align/contigs_{hap}.fa.gz' if config.get('aligner', 'minimap2') != 'lra' else 'temp/{asm_name}/align/contigs_{hap}.fa',
        gli='data/ref/ref.fa.gz.gli' if config.get('aligner', 'minimap2') == 'lra' else [],
        mmi='data/ref/ref.fa.gz.mmi' if config.get('aligner', 'minimap2') == 'lra' else []
    output:
        sam=temp('temp/{asm_name}/align/pre-cut/aligned_tig_{hap}.sam.gz')
    params:
        cpu=lambda wildcards: _align_map_cpu(wildcards, config)
    run:

        # Get aligner
        if 'aligner' in config:

            if config['aligner'] not in {'minimap2', 'lra'}:
                raise RuntimeError('Unknown "aligner" parameter in config: {}'.format(config['aligner']))

            aligner = config['aligner']

        else:
            aligner = 'minimap2'

        # Write an empty file if input is empty
        if os.stat(input.fa).st_size == 0:
            with open(output.sam, 'w') as out_file:
                pass

        # Align
        if aligner == 'minimap2':
            shell(
                """minimap2 """
                    """-x asm20 -m 10000 -z 10000,50 -r 50000 --end-bonus=100 """
                    """--secondary=no -a -t {params.cpu} --eqx -Y """
                    """-O 5,56 -E 4,1 -B 5 """
                    """{input.ref_fa} {input.fa} | """
                    """awk -vOFS="\\t" '($1 !~ /^@/) {{$10 = "*"; $11 = "*"}} {{print}}' | """
                    """gzip > {output.sam}"""
            )

        if aligner == 'lra':
            shell(
                """lra align {input.ref_fa} {input.fa} -CONTIG -p s -t {params.cpu} | """
                """awk -vOFS="\\t" '($1 !~ /^@/) {{$10 = "*"; $11 = "*"}} {{print}}' | """
                """gzip > {output.sam}"""
            )

# align_uncompress_tig
#
# Uncompress contig for aligners that cannot read gzipped FASTAs.
rule align_uncompress_tig:
    input:
        fa='temp/{asm_name}/align/contigs_{hap}.fa.gz'
    output:
        fa='temp/{asm_name}/align/contigs_{hap}.fa'
    run:

        if os.stat(input.fa).st_size > 0:
            shell(
                """zcat {input.fa} > {output.fa}"""
            )
        else:
            with open(output.fa, 'w') as out_file:
                pass

# align_get_tig_fa
#
# Get FASTA files.
rule align_get_tig_fa:
    input:
        fa=align_input_fasta
    output:
        fa=temp('temp/{asm_name}/align/contigs_{hap}.fa.gz'),
        fai=temp('temp/{asm_name}/align/contigs_{hap}.fa.gz.fai')
    run:

        # Copy FASTA to FA/GZ
        pavlib.seq.copy_fa_to_gz(input.fa, output.fa)

        # Index
        if os.stat(output.fa).st_size > 0:
            shell("""samtools faidx {output.fa}""")

        else:
            with open(output.fai, 'w') as out_file:
                pass

