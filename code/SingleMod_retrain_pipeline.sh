#!/bin/bash
# Retraining pipeline for SingleMod
SingleMod=path_to_modified_SingleMod
# Step 0 - Basecalling (to be completed before this pipeline)

# Step 1 - Mapping reads and splitting BAM file
# Map to reference genome using minimap2 externally, then split BAM for parallel processing
mkdir -p split_bam_dir
java -jar picard.jar SplitSamByNumberOfReads I=$bam SPLIT_TO_N_FILES=25 O=./split_bam_dir

# Index BAM files
for bam in split_bam_dir/*.bam; do
    samtools index "$bam"
done

# Step 2 - Nanopolish eventalign
mkdir -p eventalign_output
for file in split_bam_dir/*.bam; do
    filename=$(basename "$file" .bam)
    echo "Processing $filename"

    nanopolish eventalign \
        --reads $fq \
        --bam "$file" \
        --genome $ref \
        -t 15 \
        --scale-events \
        --samples \
        --signal-index \
        --summary eventalign_output/"${filename}_summary.txt" \
        --print-read-names > eventalign_output/"${filename}_eventalign.txt"
done

# Step 3 - Extract and organize features
mkdir -p tmp_features features

# Extract strand info from BAM (parallel)
cd split_bam_dir
for file in shard*bam; do
    bedtools bamtobed -i "$file" > "${file/.bam/.bed}" &
done
wait
cd ..

# Organize eventalign output to feature format
batch=(shard_0001 shard_0002 shard_0003 shard_0004 shard_0005 \
       shard_0006 shard_0007 shard_0008 shard_0009 shard_0010 \
       shard_0011 shard_0012 shard_0013 shard_0014 shard_0015 \
       shard_0016 shard_0017 shard_0018 shard_0019 shard_0020 \
       shard_0021 shard_0022 shard_0023 shard_0024 shard_0025)

for i in ${batch[@]}; do
    python $SingleMod/organize_from_eventalign.py -v 005 \
           -b split_bam_dir/${i}.bed \
           -e eventalign_output/${i}_eventalign.txt \
           -o tmp_features_IVET_all -p $i -s 500000
done

# Merge features
cd tmp_features
wc -l *-extra_info.txt | sed 's/^ *//g' | sed '$d' | tr " " "\t" > extra_info.txt
cd ..
python -u $SingleMod/merge_motif_npy.py -v 005 -d tmp_features -s 500000 -o features
# -v: 003 for psU, 005 for m5C, 006 for m7G

# Step 4 - Train model per motif
while read -r motif; do
    echo "Training motif: $motif"
    python $SingleMod/SingleMod_train.py -v 002 -s 293T \
        -seq features/${motif}_sequence.npy \
        -sig features/${motif}_signal.npy \
        -ext features/${motif}_extra.npy \
        -d $grouth_truth_bed \
        -m $motif -r 0 -g 0 -p 0.8 \
        -o training/motif/rep > training/motif/rep/training.log
done < motifs.txt

# $grouth_truth_bed: BED-like file with known methylation rates in 293T
# Format: chr start end . methylation_rate strand kmer

# Step 5 - Predict on held-out data
while read -r motif; do
    echo "Predicting motif: $motif"
    python $SingleMod/SingleMod_m6A_prediction.py -v 002 \
        -d features/ \
        -k "$motif" \
        -m training/motif/rep/model_"$motif".pth.tar \
        -g 0 -b 30000 \
        -o prediction_293T/"$motif"_prediction.txt
done < motifs.txt
