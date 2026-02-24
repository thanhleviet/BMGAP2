# Running BMGAP2 on a Single Linux VM

This document describes the changes made on the `local` branch to run BMGAP2 on a single Linux VM without Sun Grid Engine (SGE).

## What Changed

### `BMGAP-RUNNER.sh`

The original script required SGE (`qsub`) to submit array jobs to a cluster. The modified version runs everything locally in a sequential loop.

**SGE removal:**

- Removed `#$ -cwd` SGE directive
- Removed the `qsub -N bmgap ... -t 1-N` array job submission block and its `$SGE_TASK_ID`-based indexing
- Replaced with a `while read` loop that iterates over each FASTQ pair from the control file (`fastq.fofn`) and runs all pipeline stages sequentially on the local machine

**Thread control:**

- Added optional third argument `THREADS` (defaults to all CPUs via `nproc`)
- Exports `NSLOTS` so all child scripts pick it up — this is the same variable SGE used, so no downstream changes are needed (`Alignment.sh`, `BMScan.sh`, `PMGA.sh` already read `$NSLOTS`)

**PrepareToShare integration:**

- `PrepareToShare.sh` is now called per-sample inside the processing loop
- The original SGE script didn't include PrepareToShare in the job — it was run separately afterward. Because it expects `$RESULT_DIR/characterization/` to exist directly under its first argument, it must be called with the per-sample directory (e.g., `out/SRR8034137`), not the top-level output directory

**Bug fixes from the original script:**

- Removed duplicated version block (was copy-pasted twice)
- Removed duplicated `mkdir`/run-report block (same content appeared twice)
- Removed duplicated "Run report generated" and "BMGAP Version" lines in the report
- Fixed typos: "FASTQ input input directory" and "Analysis output output directory"
- Added proper quoting on `mkdir`, `touch`, and path arguments

**Progress and reporting:**

- Prints `[1/N] Processing sample_name...` and `[1/N] Completed sample_name.` per sample
- Tracks and reports failed sample count
- Logs start time, end time, and failure count in `run_report.txt`

## Installation

The original README describes setup with conda. On a single VM, [pixi](https://pixi.sh) is a faster alternative that the CI also uses.

### 1. Install pixi

```bash
curl -fsSL https://pixi.sh/install.sh | sh
source ~/.bashrc   # or restart your shell
```

### 2. Create the environment

```bash
cd BMGAP2
pixi init --import BMGAP_Conda_all.yml
pixi add awscli sra-tools seqtk jq bats-core csvtk
pixi install
```

All commands below assume you prefix them with `pixi run` (e.g., `pixi run python3 ...`) or activate the environment with `pixi shell`.

### 3. Download databases

```bash
# Human genome bowtie2 index (~4 GB)
pixi run aws s3 --no-sign-request --region eu-west-1 \
  sync s3://ngi-igenomes/igenomes/Homo_sapiens/NCBI/GRCh38/Sequence/Bowtie2Index/ \
  ./analysis_scripts/hg38
# Remove the raw FASTA — only the .bt2 index files are needed
rm -f ./analysis_scripts/hg38/genome.fa

# PubMLST BLAST databases (takes ~30 min, downloads from pubmlst.org)
cd analysis_scripts/PMGA && pixi run python build_pubmlst_dbs.py -o pubmlst_dbs_all && cd ../..

# RefSeq Mash sketches (~420 MB, shared by BMScan and PMGA)
wget -qO- http://gembox.cbcb.umd.edu/mash/RefSeqSketchesDefaults.msh.gz \
  | gunzip \
  | tee analysis_scripts/SpeciesDB/lib/RefSeqSketchesDefaults.msh \
  > analysis_scripts/PMGA/lib/RefSeqSketchesDefaults.msh

# LocusExtractor lookup table
gunzip analysis_scripts/locusextractor/settings_antibiotics/lookupTables/Isolate2MLST2Species.txt.gz
```

### 4. (Optional) Download test data

```bash
mkdir -p test.in/SRR8034137
pixi run fasterq-dump SRR8034137 --threads 2 --outdir test.in/SRR8034137 --split-files --skip-technical
gzip -c test.in/SRR8034137/SRR8034137_1.fastq > test.in/SRR8034137/SRR8034137_R1.fastq.gz
gzip -c test.in/SRR8034137/SRR8034137_2.fastq > test.in/SRR8034137/SRR8034137_R2.fastq.gz
rm test.in/SRR8034137/SRR8034137_1.fastq test.in/SRR8034137/SRR8034137_2.fastq
```

## Usage

```bash
BMGAP-RUNNER.sh <FASTQ_DIR> <ANALYSIS_DIRECTORY> [THREADS]
```

| Argument | Required | Description |
|---|---|---|
| `FASTQ_DIR` | Yes | Directory containing paired-end `*R1*.fastq.gz` / `*R2*.fastq.gz` files |
| `ANALYSIS_DIRECTORY` | Yes | Directory where results will be written |
| `THREADS` | No | Number of CPU threads (default: all available via `nproc`) |

Example:

```bash
bash BMGAP-RUNNER.sh test.in/SRR8034137 out 4
```

## Output Directory Structure

The runner creates a per-sample subdirectory under the analysis directory. For a sample named `SRR8034137`:

```
out/
  run_report.txt                  # Pipeline run metadata
  fastq.fofn                      # FASTQ pair manifest (tab-separated R1/R2 paths)
  log/                            # Log directory
  SRR8034137/                     # Per-sample output directory
    SRR8034137_output.o           # Combined stdout from all stages
    SRR8034137_error.e            # Combined stderr from all stages
    SRR8034137.human.bam          # Human reads removed by bowtie2
    SRR8034137_R1_dedup_NoHuman.fastq.gz
    SRR8034137_R2_dedup_NoHuman.fastq.gz
    SRR8034137_R1_dedup_NoHuman_cutTruSeq_trim.fastq.gz
    SRR8034137_R2_dedup_NoHuman_cutTruSeq_trim.fastq.gz
    SRR8034137_SPAdes/            # SPAdes assembly output
      scaffolds.fasta             # Final assembled scaffolds
      contigs.fasta
      spades.log
      ...
    AssemblyCleanup/
      SRR8034137_DIS.fasta        # Cleaned assembly stats
      SRR8034137_DIS.fasta.report.tab
      SRR8034137_DIS.fasta.report.png
      SRR8034137_DIS_discarded.fasta
    characterization/
      SRR8034137_cleaned.fasta    # QC-filtered assembly used by all downstream tools
      BMScan/
        species_analysis_<timestamp>.json
        species_analysis_<timestamp>.csv
      PMGA/
        scheme_counts.json
        allele_matrix.tab
        loci_counts.tab
        json/
          SRR8034137_cleaned_final_results.json
          SRR8034137_cleaned_raw_results.json
        gff/
          SRR8034137_cleaned.gff
        serogroup/
          serogroup_predictions_<timestamp>.tab
          serogroup_results.json
        feature_fastas/SRR8034137_cleaned/
          CDS.fasta
          PEP.fasta
          IGR.fasta
          ISE.fasta
          PRO.fasta
      LE_<version>_<sample>_<timestamp>/
        molecular_data_SRR8034137.json
        molecular_data_SRR8034137.xlsx
        allele_data_SRR8034137.xlsx
        sequence_data_SRR8034137.csv
        Results_text/
          molecular_data_SRR8034137.csv
          allele_data_SRR8034137.csv
        lookup_data_SRR8034137/
        References_<timestamp>/
      AMR_SRR8034137/
        SRR8034137_amr_data.json
        SRR8034137_new_allele.fasta
        SRR8034137_gene_db.xlsx
        SRR8034137_PMGA_alleles.xlsx
        SRR8034137_PMGA_mutations.xlsx
        runAST.log
    shareFiles/                   # PrepareToShare output (ready for CDC submission)
      assembly_cleaned.fasta
      bmscan_species_analysis.json
      bmscan_species_analysis.csv
      amr_data.json
      le_molecular_data.json
      le_molecular_data.csv
      pmga_scheme_counts.json
      pmga_cleaned_final_results.json
      pmga_serogroup_results.json
      pmga_serogroup_predictions.tab
```

## Expected Output for Test Isolate SRR8034137

SRR8034137 is *Neisseria meningitidis* serogroup B. Below are the key result files and their expected content.

### Species Identification (BMScan)

`species_analysis_<timestamp>.json`:

```json
{
  "SRR8034137_cleaned.fasta": {
    "mash_results": {
      "species": "Neisseria meningitidis",
      "top_hit": "M08865_HUY3758A22_cleaned.fasta",
      "mash_pval": "0",
      "mash_hash": "955/1000",
      "score": 0.9988911,
      "source": "BML_collection",
      "notes": "Hit above threshold"
    }
  }
}
```

### Serogroup Predictions (PMGA)

`serogroup_predictions_<timestamp>.tab` (tab-delimited):

| Query | SG | Genes_Present | Notes |
|---|---|---|---|
| SRR8034137_cleaned | B | csb,cssA,cssB,cssC,ctrA,ctrB,ctrC,ctrD,ctrE,ctrF,tex | B backbone: All essential capsule genes intact and present |

### MLST (LocusExtractor)

Key fields from `molecular_data_SRR8034137.json` for the assembly (index `"0"`):

| Locus | Allele |
|---|---|
| Nm_MLST_abcZ | 4 |
| Nm_MLST_adk | 10 |
| Nm_MLST_aroE | 5 |
| Nm_MLST_fumC | 4 |
| Nm_MLST_gdh | 6 |
| Nm_MLST_pdhC | 3 |
| Nm_MLST_pgm | 8 |
| Nm_MLST_ST | 32 |
| Nm_MLST_cc | CC32 |
| PorA_type | P1.7,16-20 |
| FetA | F3-3 |
| FHbp_protein_subvariant_Novartis | 1.1 |
| NhbA_Protein_subvariant_Novartis | p0005 |
| NadA_Protein_subvariant_Novartis | NadA-1.1 |

All Hi_MLST loci are "Not found" (expected, since this is *N. meningitidis*).

### AMR Analysis

`SRR8034137_amr_data.json` (key sections):

**Resistance prediction:**

```json
{
  "antimicrobics": {
    "Penicillins": {
      "Penicillin": {
        "markers": { "penA mosaic": "Intermediate" },
        "predicted_phenotype": "Intermediate"
      }
    }
  },
  "summary": {
    "predicted_resistance": "None"
  }
}
```

**AMR genes detected (present):**

| NEIS ID | Gene | Allele | Antimicrobial | Known Mutations |
|---|---|---|---|---|
| NEIS1320 | gyrA | 2 | Fluoroquinolones | None |
| NEIS0414 | ponA | 52 | Penicillins | None |
| NEIS1753 | penA | 786 | Penicillins | F504L, A510V, N512Y, I515V, H541N, I566V |
| NEIS0123 | rpoB | 4 | Rifampin | None |
| NEIS1525 | parC | 51 | Fluoroquinolones | None |

penA allele 786 carries 6 known resistance-associated substitutions affecting Penicillin, Ampicillin, and Cephalosporins. The overall predicted phenotype is **Intermediate** for Penicillin, with no predicted resistance to other antimicrobials.

### PMGA Scheme Counts

`scheme_counts.json` contains locus hit counts across all PubMLST schemes. Key counts for this isolate:

| Scheme | Loci Found |
|---|---|
| MLST | 7 |
| N_meningitidis_cgMLST_v1 | 1576 |
| Human-restricted_Neisseria_cgMLST_v1_0 | 1417 |
| Capsule_Region_A_-_Serogroup_B | 5 |
| Antibiotic_resistance | 11 |
| Mendevar | 7 |
| Bexsero_Antigen_Sequence_Typing_(BAST) | 5 |

### Run Report

`run_report.txt`:

```
Current path: /home/ubuntu/BMGAP2
Run report generated: 2026-02-24 18:00:11
BMGAP Version: 2.2.0
FASTQ input directory: /home/ubuntu/BMGAP2/test.in/SRR8034137
Analysis output directory: /home/ubuntu/BMGAP2/out
Analysis scripts directory: /home/ubuntu/BMGAP2/analysis_scripts
Threads: 4

Full results directory: /home/ubuntu/BMGAP2/out
Note: Individual sample output directories are under the analysis directory.
Completed: 2026-02-24 19:19:14
Samples processed: 1 (failed: 0)
```

## Running PMGA Standalone on Existing Contigs

If you already have assembled contig FASTA files and only need PMGA annotation (serogroup/serotype, allele identification, scheme counts), you can call `blast_pubmlst.py` directly without running the full pipeline.

### Basic usage

```bash
# Put your FASTA file(s) in a directory
mkdir -p my_contigs
cp sample1.fasta sample2.fasta my_contigs/

# Run PMGA on all FASTAs in the directory
python3 analysis_scripts/PMGA/blast_pubmlst.py \
  -d my_contigs \
  -o pmga_results \
  -sc -a -sg -p -fa \
  -t $(nproc)
```

### Flags

| Flag | Description |
|---|---|
| `-d DIR` | Input directory containing `.fasta` files (processes all FASTAs found) |
| `-o DIR` | Output directory |
| `-sg` | Produce serogroup prediction file |
| `-sc` | Produce tab-delimited scheme locus counts |
| `-a` | Produce allele matrix across all tested genomes |
| `-p` | Query PubMLST REST API for annotations |
| `-fa` | Output identified gene sequences as FASTAs |
| `-t N` | Number of threads (default: 1) |
| `-s FILE` | Provide existing BMScan JSON to skip species re-identification |
| `-fr` | Force overwrite existing output |
| `-x FILE` | Use an Excel file with `Filename` column instead of `-d` |

### How it differs from PMGA.sh

The wrapper script `PMGA.sh` adds a species gate: it reads BMScan CSV output and only runs PMGA if the species is *N. meningitidis* or *H. influenzae*. When calling `blast_pubmlst.py` directly, there is no species gate — it runs BMScan internally via Mash sketch and annotates accordingly.

If you already have BMScan results, pass them with `-s` to skip the internal species identification:

```bash
python3 analysis_scripts/PMGA/blast_pubmlst.py \
  -d my_contigs \
  -o pmga_results \
  -s path/to/species_analysis.json \
  -sc -a -sg -p -fa \
  -t $(nproc)
```

### Output structure

```
pmga_results/
  scheme_counts.json                          # Locus counts per PubMLST scheme
  allele_matrix.tab                           # Allele IDs per genome
  loci_counts.tab                             # Per-locus hit counts
  json/
    <sample>_final_results.json               # Annotated results per genome
    <sample>_raw_results.json                 # Raw BLAST results
  gff/
    <sample>.gff                              # Gene annotations in GFF format
  serogroup/
    serogroup_predictions_<timestamp>.tab     # Serogroup calls (tab-delimited)
    serogroup_results.json                    # Serogroup details as JSON
  feature_fastas/<sample>/
    CDS.fasta                                 # Coding sequences
    PEP.fasta                                 # Peptide translations
    IGR.fasta                                 # Intergenic regions
    ISE.fasta                                 # Insertion elements
    PRO.fasta                                 # Promoter sequences
```

### Prerequisites

PMGA requires these databases to be set up before first use (same as the full pipeline):

```bash
# PubMLST BLAST databases
cd analysis_scripts/PMGA && python build_pubmlst_dbs.py -o pubmlst_dbs_all

# RefSeq Mash sketches (needed for internal BMScan)
wget -qO- http://gembox.cbcb.umd.edu/mash/RefSeqSketchesDefaults.msh.gz \
  | gunzip > analysis_scripts/PMGA/lib/RefSeqSketchesDefaults.msh
```

## Differences from the SGE Version

| Aspect | Original (SGE) | Local |
|---|---|---|
| Job execution | `qsub` array jobs, up to 2 concurrent | Sequential `while read` loop |
| Thread control | SGE `$NSLOTS` (set by scheduler) | CLI argument or `nproc` auto-detect, exported as `$NSLOTS` |
| Output layout | Flat `out/characterization/` | Per-sample `out/<sample>/characterization/` |
| PrepareToShare | Run manually after all jobs finish | Integrated per-sample at end of each iteration |
| Progress | SGE job log files | Console output with `[N/M]` counters |
| Dependencies | SGE cluster + conda | Single Linux VM + conda/pixi |
