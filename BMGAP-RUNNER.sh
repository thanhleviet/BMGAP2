#! /bin/bash

# Written by ujz6 on 02/25/2025

###########################################
# Function to display the usage message
usage() {
    echo "Usage: $0 <FASTQ_DIR> <ANALYSIS_DIRECTORY> [THREADS]"
    echo
    echo "Required Arguments:"
    echo "  FASTQ_DIR            Directory with FASTQ locations."
    echo "  ANALYSIS_DIRECTORY   Directory for results."
    echo
    echo "Optional Arguments:"
    echo "  THREADS              Number of CPU threads to use (default: all available)."
    echo
}

# Script versioning (BMGAP Version, found in GitHub)
SCRIPT_VERSION="2"
SCRIPT_SUBVERSION="2.0"
export BMGAP_VERSION="$SCRIPT_VERSION.$SCRIPT_SUBVERSION"

# Check if no arguments or insufficient arguments are provided
if [[ $# -lt 2 ]]; then
    usage
    exit 1
fi
###########################################

###########################################
#Defining directories containing FASTQ files and analysis
FASTQ_DIR=${1}
ANALYSIS_DIRECTORY=${2}
export NSLOTS=${3:-$(nproc)}

PATH2="$(pwd)"
ANALYSIS_SCRIPTS="$PATH2/analysis_scripts"

# Check if FASTQ_DIR exists and is a directory
if [[ ! -d "$FASTQ_DIR" ]]; then
    echo "Error: The directory '$FASTQ_DIR' does not exist or is not a valid directory."
    exit 1
fi

# Check if FASTQ_DIR contains .fastq.gz files
if ! ls "$FASTQ_DIR"/*.fastq.gz &>/dev/null; then
    echo "Error: No fastq.gz files found in the directory '$FASTQ_DIR'."
    exit 1
fi

mkdir -p "$ANALYSIS_DIRECTORY"
###########################################

# Prepare run report
RUN_REPORT="$ANALYSIS_DIRECTORY/run_report.txt"
START_TIME=$(date +"%Y-%m-%d %H:%M:%S")

{
echo "Current path: $PATH2"
echo "Run report generated: $START_TIME"
echo "BMGAP Version: $SCRIPT_VERSION.$SCRIPT_SUBVERSION"
echo "FASTQ input directory: $FASTQ_DIR"
echo "Analysis output directory: $ANALYSIS_DIRECTORY"
echo "Analysis scripts directory: $ANALYSIS_SCRIPTS"
echo "Threads: $NSLOTS"
echo
} > "$RUN_REPORT"

LOG_DIR="$ANALYSIS_DIRECTORY/log"
mkdir -p "$LOG_DIR"
CTRL_FILE="$ANALYSIS_DIRECTORY/fastq.fofn"
touch "$CTRL_FILE"
###########################################

echo "Beginning analysis of isolates"
echo ""
#Loop through all R1 files in the Directory
for r1_file in "$FASTQ_DIR"/*R1*.fastq.gz; do
	#Check if file exists
	if [[ ! -f $r1_file ]]; then
		echo "No R1 files found (expected: $r1_file) ." >> "$RUN_REPORT"
		echo "No R1 files found in $FASTQ_DIR, please use a different directory" >> "$RUN_REPORT"
		exit 1
	fi

	#Derive the corresponding R2 filename from R1 filename
	r2_file="${r1_file/R1/R2}"  # Replace 'R1' with 'R2'

	#Check if the corresponding R2 file exists
	if [[ -f $r2_file ]]; then
		echo -e "$r1_file\t$r2_file"
	else
		echo "Warning: Corresponding R2 file not found for $r1_file. Skipping this pair." >&2
	fi
done > "$CTRL_FILE"

NUM_SAMPLES=$(wc -l < "$CTRL_FILE")
if [[ "$NUM_SAMPLES" -eq 0 ]]; then
	echo "Error: No valid FASTQ pairs found." >&2
	exit 1
fi

echo "Processing $NUM_SAMPLES sample(s) with $NSLOTS thread(s)..."

SAMPLE_IDX=0
FAILED=0

while IFS=$'\t' read -r r1_file r2_file; do
	SAMPLE_IDX=$((SAMPLE_IDX + 1))

	#Extract base name without path
	base_name=$(basename "$r1_file" .fastq.gz)
	base_name=${base_name%%_*} #Gets only M#
	OUTPUT_DIR="$ANALYSIS_DIRECTORY/$base_name"
	mkdir -p "$OUTPUT_DIR"

	# Define error and output file paths for isolate
	error_file="$OUTPUT_DIR/${base_name}_error.e"
	output_file="$OUTPUT_DIR/${base_name}_output.o"

	echo "[$SAMPLE_IDX/$NUM_SAMPLES] Processing $base_name..."

	# Align PE-FASTQ files and remove human DNA
	echo "Alignment of $base_name." | tee --append "$output_file" "$error_file"
	bash "$ANALYSIS_SCRIPTS/Alignment.sh" "$r1_file" "$r2_file" "$OUTPUT_DIR" "$base_name" \
		>> "$output_file" 2>> "$error_file"

	# Assembly cleanup, check QC
	echo "AssemblyCleanup for $base_name." | tee --append "$output_file" "$error_file"
	bash "$ANALYSIS_SCRIPTS/cleanupSingle.sh" "$OUTPUT_DIR" "$base_name" \
		>> "$output_file" 2>> "$error_file"

	# Run BMScan on each new fasta file
	echo "BMSCAN for $base_name." | tee --append "$output_file" "$error_file"
	bash "$ANALYSIS_SCRIPTS/BMScan.sh" "$OUTPUT_DIR" "$base_name" \
		>> "$output_file" 2>> "$error_file"

	# Run PMGA on each new fasta file
	echo "PMGA for $base_name." | tee --append "$output_file" "$error_file"
	bash "$ANALYSIS_SCRIPTS/PMGA.sh" "$OUTPUT_DIR" "$base_name" \
		>> "$output_file" 2>> "$error_file"

	# Run LocusExtractor on each new fasta file
	echo "LocusExtractor for $base_name." | tee --append "$output_file" "$error_file"
	bash "$ANALYSIS_SCRIPTS/LocusExtractor.sh" "$OUTPUT_DIR" "$base_name" \
		>> "$output_file" 2>> "$error_file"

	# Run AMR with species code for each sample
	echo "AMR for $base_name." | tee --append "$output_file" "$error_file"
	bash "$ANALYSIS_SCRIPTS/AMR.sh" "$OUTPUT_DIR" "$base_name" \
		>> "$output_file" 2>> "$error_file"

	# Package results for sharing
	echo "PrepareToShare for $base_name." | tee --append "$output_file" "$error_file"
	bash "$ANALYSIS_SCRIPTS/PrepareToShare.sh" "$OUTPUT_DIR" "$base_name" \
		>> "$output_file" 2>> "$error_file"

	if [[ $? -ne 0 ]]; then
		echo "Warning: Sample $base_name finished with errors. Check $error_file" >&2
		FAILED=$((FAILED + 1))
	fi

	echo "[$SAMPLE_IDX/$NUM_SAMPLES] Completed $base_name."

done < "$CTRL_FILE"

END_TIME=$(date +"%Y-%m-%d %H:%M:%S")

{
echo
echo "Full results directory: $ANALYSIS_DIRECTORY"
echo "Note: Individual sample output directories are under the analysis directory."
echo "Completed: $END_TIME"
echo "Samples processed: $NUM_SAMPLES (failed: $FAILED)"
} >> "$RUN_REPORT"

echo "Pipeline complete. $NUM_SAMPLES sample(s) processed ($FAILED failed)."
echo "Results: $ANALYSIS_DIRECTORY"
echo "Run report: $RUN_REPORT"
