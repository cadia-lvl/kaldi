#!/bin/bash -eu

set -o pipefail

# This script cleans and preprocesses data for punctuation modelling.

#date
d=$(date +'%Y%m%d')

stage=0
id=
ignore_commas=true
suffix=
$ignore_commas && suffix=_noCOMMA

. ./path.sh # root_* and $data defined as well here
. ./utils/parse_options.sh

# These paths are defined in path.conf
prondict=$(ls -t $root_lexicon/prondict.*.txt | head -n1)
abbr_list=$(ls -t $root_text_norm_listdir/abbreviation_list.*.txt | head -n1)
punct_transcripts=$root_punctuation_transcripts
punct_transcirpts_archive=$root_punct_transcripts_archive

if [ $suffix = "_noCOMMA" ]; then
  current_punct_data=$(ls -td $root_punctuation_datadir/*/first_stage_noCOMMA | head -n1)
  new_datadir=$root_punctuation_datadir/$d/first_stage_noCOMMA
else
  current_punct_data=$(ls -td $root_punctuation_datadir/*/first_stage | head -n1)
  new_datadir=$root_punctuation_datadir/$d/first_stage
fi

mkdir -p $new_datadir/log

tmp=$(mktemp -d)
cleanup () {
    rm -rf "$tmp"
}
trap cleanup EXIT

cat $punct_transcripts/*.txt > $tmp/new_transcripts.txt
mv $punct_transcripts/*.txt $punct_transcripts_archive/

echo "Preprocess the data for training"
utils/slurm.pl --mem 8G ${new_datadir}/log/preprocessing_trainingdata_cs.log \
       python punctuator/local/preprocessing_trainingdata_cs.py $tmp/new_transcripts.txt $tmp/new_transcripts_processed.txt || exit 1;
cat $current_punct_data/althingi.train.txt $tmp/new_transcripts_processed.txt > ${new_datadir}/althingi.train.txt

# Use the same dev and test data as before
cat $current_punct_data/althingi.dev.txt ${new_datadir}/althingi.dev.txt
cat $current_punct_data/althingi.test.txt ${new_datadir}/althingi.test.txt

# If I want to ignore commas in the training:
if [ $ignore_commas = true ]; then
  for f in althingi.{train,dev,test}.txt; do
    sed -i -re 's: ,COMMA::g' $new_datadir/$f
  done
fi

echo "Preprocessing done."
    
exit 0;