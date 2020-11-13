##########################################################################################

## Base script:   https://portal.firecloud.org/#methods/Talkowski-SV/04_v2_make_cohort_VCFs/3/wdl

## Github commit: talkowski-lab/gatk-sv-v1:<ENTER HASH HERE IN FIRECLOUD>

##########################################################################################

version 1.0

import "Structs.wdl"

workflow MergeCohortVcfs {
  input {
    Array[File] depth_vcfs    # Filtered depth VCFs across batches
    Array[File] pesr_vcfs     # Filtered PESR VCFs across batches
    String cohort             # Cohort name or project prefix for all cohort-level outputs
    File contig_list
    String sv_pipeline_docker
    String sv_base_mini_docker
    RuntimeAttr? runtime_attr_merge_pesr
    RuntimeAttr? runtime_attr_merge_depth
    RuntimeAttr? runtime_attr_regeno_raw_combined_depth
    RuntimeAttr? runtime_attr_regeno_merged_depth
    RuntimeAttr? runtime_attr_sample_lookup
    RuntimeAttr? runtime_attr_concat_samplecountlookup
    RuntimeAttr? runtime_attr_concat_sampleidlookup
  }

  Array[Array[String]] contigs = read_tsv(contig_list)

  call MergeVcfs as MergePESRVcfs {
    input:
      vcfs = pesr_vcfs,
      prefix = cohort + ".all_batches.pesr",
      sv_pipeline_docker = sv_pipeline_docker,
      runtime_attr_override = runtime_attr_merge_pesr
  }

  call MergeDepthVcfs {
    input:
      vcfs = depth_vcfs,
      cohort = cohort,
      prefix = cohort + ".all_batches.depth",
      sv_pipeline_docker = sv_pipeline_docker,
      runtime_attr_override = runtime_attr_merge_depth
  }

  call MakeRawCombinedBed {
    input:
      vcfs = depth_vcfs,
      cohort = cohort,
      sv_pipeline_docker = sv_pipeline_docker,
      runtime_attr_override = runtime_attr_regeno_raw_combined_depth
  }

  call MakeMergedDepthBeds {
    input:
      regeno_raw_combined_depth = MakeRawCombinedBed.regeno_raw_combined_depth,
      cohort = cohort,
      sv_pipeline_docker = sv_pipeline_docker,
      runtime_attr_override = runtime_attr_regeno_merged_depth
  }

  scatter (contig in contigs) {
    call MakeSampleLookupBeds {
      input:
        regeno_merged_depth = MakeMergedDepthBeds.regeno_merged_depth,
        regeno_merged_depth_clustered = MergeDepthVcfs.regeno_merged_depth_clustered,
        cohort = cohort,
        contig = contig[0],
        sv_pipeline_docker = sv_pipeline_docker,
        runtime_attr_override = runtime_attr_sample_lookup
    }
  }

  call ConcatBed as ConcatSampleCountLookupBed {
    input: 
      bed_shards = MakeSampleLookupBeds.regeno_sample_counts_lookup,
      filename = cohort + ".regeno.sample_counts_lookup.bed",
      sv_base_mini_docker = sv_base_mini_docker,
      runtime_attr_override = runtime_attr_concat_samplecountlookup
  }

  call ConcatBed as ConcatSampleIdLookupBed {
    input: 
      bed_shards = MakeSampleLookupBeds.regeno_sample_ids_lookup,
      filename = cohort + ".regeno.sample_ids_lookup.bed",
      sv_base_mini_docker = sv_base_mini_docker,
      runtime_attr_override = runtime_attr_concat_sampleidlookup
  }

  output {
    File cohort_pesr_vcf = MergePESRVcfs.merged_vcf
    File cohort_depth_vcf = MergeDepthVcfs.merged_vcf
    File regeno_merged_depth = MakeMergedDepthBeds.regeno_merged_depth
    File regeno_raw_combined_depth = MakeRawCombinedBed.regeno_raw_combined_depth
    File regeno_sample_counts_lookup = ConcatSampleCountLookupBed.concat_bed
    File regeno_sample_ids_lookup = ConcatSampleIdLookupBed.concat_bed
  }
}

task MergeVcfs {
  input {
    Array[File] vcfs
    String prefix
    String sv_pipeline_docker
    RuntimeAttr? runtime_attr_override
  }

  RuntimeAttr default_attr = object {
    cpu_cores: 1, 
    mem_gb: 3.75, 
    disk_gb: 10,
    boot_disk_gb: 10,
    preemptible_tries: 3,
    max_retries: 1
  }
  RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

  output {
    File merged_vcf = "~{prefix}.vcf.gz"
  }
  command <<<

    set -euo pipefail
    /opt/sv-pipeline/04_variant_resolution/scripts/merge_vcfs.py ~{write_lines(vcfs)} ~{prefix}.vcf
    rm ~{sep=' ' vcfs}
    vcf-sort -c ~{prefix}.vcf | bgzip -c > ~{prefix}.vcf.gz
  
  >>>
  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GiB"
    disks: "local-disk " + select_first([runtime_attr.disk_gb, default_attr.disk_gb]) + " HDD"
    bootDiskSizeGb: select_first([runtime_attr.boot_disk_gb, default_attr.boot_disk_gb])
    docker: sv_pipeline_docker
    preemptible: select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }
}

task MergeDepthVcfs {
  input {
    Array[File] vcfs
    String cohort
    String prefix
    String sv_pipeline_docker
    RuntimeAttr? runtime_attr_override
  }

  RuntimeAttr default_attr = object {
    cpu_cores: 1, 
    mem_gb: 3.75, 
    disk_gb: 10,
    boot_disk_gb: 10,
    preemptible_tries: 3,
    max_retries: 1
  }
  RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

  output {
    File merged_vcf = "~{prefix}.vcf.gz"
    File regeno_merged_depth_clustered = "~{cohort}.regeno.merged_depth_clustered.bed"
  }
  command <<<

    set -euxo pipefail
    /opt/sv-pipeline/04_variant_resolution/scripts/merge_vcfs.py ~{write_lines(vcfs)} ~{prefix}.vcf
    rm ~{sep=' ' vcfs}
    vcf-sort -c ~{prefix}.vcf | bgzip -c > ~{prefix}.vcf.gz
    svtk vcf2bed ~{prefix}.vcf.gz ~{prefix}.vcf.gz.bed   # vcf2bed merge_vcfs, non_duplicated
    # split DELs and DUPs into separate, non-duplicated BED files. SVTYPE is 5th column of BED
    awk -F "\t" -v OFS="\t" '{ if ($5 == "DEL") { print > "del.bed" } else if ($5 == "DUP") { print > "dup.bed" } }' ~{prefix}.vcf.gz.bed 
    svtk bedcluster del.bed | cut -f1-7 | awk '{print $0","}' > del.cluster.bed #cluster non_duplicated del
    svtk bedcluster dup.bed | cut -f1-7 | awk '{print $0","}' > dup.cluster.bed #cluster non_duplicated dup
    cat del.cluster.bed dup.cluster.bed | sort -k1,1V -k2,2n -k3,3n | fgrep -v "#" > ~{cohort}.regeno.merged_depth_clustered.bed #combine clusterd non-duplicated
  >>>
  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GiB"
    disks: "local-disk " + select_first([runtime_attr.disk_gb, default_attr.disk_gb]) + " HDD"
    bootDiskSizeGb: select_first([runtime_attr.boot_disk_gb, default_attr.boot_disk_gb])
    docker: sv_pipeline_docker
    preemptible: select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }
}

task MakeRawCombinedBed {
  input {
    Array[File] vcfs
    String cohort
    String sv_pipeline_docker
    RuntimeAttr? runtime_attr_override
  }

  RuntimeAttr default_attr = object {
    cpu_cores: 1, 
    mem_gb: 3.75, 
    disk_gb: 10,
    boot_disk_gb: 10,
    preemptible_tries: 3,
    max_retries: 1
  }
  RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

  output {
    File regeno_raw_combined_depth = "~{cohort}.regeno.raw_combined_depth.bed"
  }
  command <<<

    set -euxo pipefail
    while read vcf; do
        local_vcf=$(basename $vcf)
        svtk vcf2bed --no-header $vcf $local_vcf.bed   # for each depth vcf make bed, duplicated
    done < ~{write_lines(vcfs)}
    rm ~{sep=' ' vcfs}
    cat *.bed | sort -k1,1V -k2,2n -k3,3n > ~{cohort}.regeno.raw_combined_depth.bed # concat raw depth vcf, duplicated
  >>>
  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GiB"
    disks: "local-disk " + select_first([runtime_attr.disk_gb, default_attr.disk_gb]) + " HDD"
    bootDiskSizeGb: select_first([runtime_attr.boot_disk_gb, default_attr.boot_disk_gb])
    docker: sv_pipeline_docker
    preemptible: select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }
}

task MakeMergedDepthBeds {
  input {
    File regeno_raw_combined_depth
    String cohort
    String sv_pipeline_docker
    RuntimeAttr? runtime_attr_override
  }

  RuntimeAttr default_attr = object {
    cpu_cores: 1, 
    mem_gb: 3.75, 
    disk_gb: 10,
    boot_disk_gb: 10,
    preemptible_tries: 3,
    max_retries: 1
  }
  RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

  output {
    File regeno_merged_depth="~{cohort}.regeno.merged_depth.bed"
  }
  command <<<

    set -euxo pipefail
    python3 <<CODE
    varID={}
    with open("~{regeno_raw_combined_depth}",'r') as f: # From the depth cohort bed, a dictionary of all duplicate variants and their samples
        for line in f:
            dat=line.rstrip().split('\t')
            samples=dat[-1].split(",")
            var=dat[3]
            ID=dat[0]+":"+dat[1]+'-'+dat[2]+'_'+dat[4]
            if ID not in varID.keys():
                varID[ID]={"sample":samples,"varids":[var]}
            else:
                varID[ID]['sample']=varID[ID]['sample']+samples
                varID[ID]['varids'].append(var)
    with open("~{cohort}.regeno.merged_depth.bed",'w') as f: # For each unique variant a line with variants and samples
        for variant in varID.keys():
            CHROM=variant.split(":")[0]
            START=variant.split(':')[1].split("-")[0]
            END=variant.split(':')[1].split("-")[1].split('_')[0]
            varcol=":".join(varID[variant]["varids"])+':'
            samplecol=",".join(varID[variant]['sample'])+','
            f.write(CHROM+"\t"+START+"\t"+END+"\t"+varcol+"\t"+samplecol+'\n')
    CODE
  >>>
  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GiB"
    disks: "local-disk " + select_first([runtime_attr.disk_gb, default_attr.disk_gb]) + " HDD"
    bootDiskSizeGb: select_first([runtime_attr.boot_disk_gb, default_attr.boot_disk_gb])
    docker: sv_pipeline_docker
    preemptible: select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }
}

task MakeSampleLookupBeds {
  input {
    File regeno_merged_depth
    File regeno_merged_depth_clustered
    String cohort
    String contig
    String sv_pipeline_docker
    RuntimeAttr? runtime_attr_override
  }

  RuntimeAttr default_attr = object {
    cpu_cores: 1, 
    mem_gb: 3.75, 
    disk_gb: 10,
    boot_disk_gb: 10,
    preemptible_tries: 3,
    max_retries: 1
  }
  RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

  output {
    File regeno_sample_counts_lookup = "~{contig}.regeno.sample_counts_lookup.bed"
    File regeno_sample_ids_lookup = "~{contig}.regeno.sample_ids_lookup.bed"
  }
  command <<<

    set -euxo pipefail
    # select rows of BED files pertaining to contig - chrom is 1st column of each BED file
    awk -F "\t" -v OFS="\t" '{ if ($1 == "~{contig}") { print > "~{contig}.regeno.merged_depth.bed" } }' ~{regeno_merged_depth}
    awk -F "\t" -v OFS="\t" '{ if ($1 == "~{contig}") { print > "~{contig}.regeno.merged_depth_clustered.bed" } }' ~{regeno_merged_depth_clustered}
    python3 <<CODE
    # dictionary of (samples, varIDs) for de-duplicated variant for EACH varID corresponding to that unique variant
    varID_data = {} 
    with open("~{contig}.regeno.merged_depth.bed","r") as f: # for EACH variant ID, a list of duplicate variants and samples
        for line in f:
            dat=line.split('\t')
            varIDs_list = dat[3].split(":")[0:-1]
            samples_list = dat[4].split(',')[0:-1]
            for varID in varIDs_list:
                varID_data[varID] = (samples_list, varIDs_list)
    with open("~{contig}.regeno.sample_counts_lookup.bed",'w') as g: # Using clustered merged (de-dupped) depth calls, for each clustered variant get varIDs and samples of the component calls
        with open("~{contig}.regeno.merged_depth_clustered.bed","r") as f:
            for line in f:
                samples=[]
                variants=[]
                dat=line.rstrip().split("\t")
                for varID in dat[6][0:-1].split(','):
                    samples.extend(varID_data[varID][0]) # samples are first in tuple
                    samples = list(set(samples))
                    variants.extend(varID_data[varID][1]) # variant IDs are 2nd in tuple
                    variants = list(set(variants))
                g.write(dat[0]+'\t'+dat[1]+'\t'+dat[2]+'\t'+dat[3]+'\t'+dat[4]+'\t'+dat[5]+'\t'+":".join(variants)+':\t'+str(len(samples))+'\n')
    with open("~{contig}.regeno.sample_ids_lookup.bed",'w') as g:
        with open("~{contig}.regeno.merged_depth_clustered.bed","r") as f:
            for line in f:
                samples=[]
                variants=[]
                dat=line.rstrip().split("\t")
                for varID in dat[6][0:-1].split(','):
                    samples.extend(varID_data[varID][0]) # samples are first in tuple
                    samples = list(set(samples))
                    variants.extend(varID_data[varID][1]) # variant IDs are 2nd in tuple
                    variants = list(set(variants))
                g.write(dat[0]+'\t'+dat[1]+'\t'+dat[2]+'\t'+dat[3]+'\t'+dat[4]+'\t'+dat[5]+'\t'+":".join(variants)+':\t'+','.join(samples)+',\n')
    CODE
  >>>
  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GiB"
    disks: "local-disk " + select_first([runtime_attr.disk_gb, default_attr.disk_gb]) + " HDD"
    bootDiskSizeGb: select_first([runtime_attr.boot_disk_gb, default_attr.boot_disk_gb])
    docker: sv_pipeline_docker
    preemptible: select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }
}

task ConcatBed {
  input {
    Array[File] bed_shards
    String filename
    String sv_base_mini_docker
    RuntimeAttr? runtime_attr_override
  }

  RuntimeAttr default_attr = object {
    cpu_cores: 1, 
    mem_gb: 3.75, 
    disk_gb: 10,
    boot_disk_gb: 10,
    preemptible_tries: 3,
    max_retries: 1
  }
  RuntimeAttr runtime_attr = select_first([runtime_attr_override, default_attr])

  output {
    File concat_bed = "~{filename}"
  }
  command <<<
    set -euxo pipefail
    while read bed_shard; do
      cat $bed_shard >> ~{filename} # all BED files are headless and sorted so can just concatenate in order
    done < ~{write_lines(bed_shards)}
  >>>
  runtime {
    cpu: select_first([runtime_attr.cpu_cores, default_attr.cpu_cores])
    memory: select_first([runtime_attr.mem_gb, default_attr.mem_gb]) + " GiB"
    disks: "local-disk " + select_first([runtime_attr.disk_gb, default_attr.disk_gb]) + " HDD"
    bootDiskSizeGb: select_first([runtime_attr.boot_disk_gb, default_attr.boot_disk_gb])
    docker: sv_base_mini_docker
    preemptible: select_first([runtime_attr.preemptible_tries, default_attr.preemptible_tries])
    maxRetries: select_first([runtime_attr.max_retries, default_attr.max_retries])
  }
}
