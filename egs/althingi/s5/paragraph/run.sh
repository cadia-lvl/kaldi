#!/bin/bash -e

set -o pipefail

# Prepare data for paragraph model training, train the model, compare with the test sets and calculate the errors. NOTE! Need updating!
# Run from the s5 dir

stage=0
continue_with_previous=false    # continue training an existing model

. ./path.sh
. ./utils/parse_options.sh
. ./local/utils.sh
. ./local/array.sh

#date
d=$(date +'%Y%m%d')

source activate thenv || error 11 ${error_array[11]};

# The root dirs are defined in conf/path.conf (set in path.sh)
inputdatadir=$root_intermediate
modeldir=$root_paragraph_modeldir/${d}
datadir=$root_paragraph_datadir/${d}
mkdir -p $datadir/log $modeldir/log

source $CONDAPATH/activate thenv || error 11 ${error_array[11]};

if [ $stage -le -1 ]; then
  
  echo "Clean and preprocess the training data"
  paragraph/local/prep_data_for_paragraph_model.sh $inputdatadir $datadir || exit 1;
fi

# Check the number of paragraphs I have
#sed -r 's:EOP:\n:g' ${dir}/althingi.dev.txt | awk '{print NF}' | awk '{ sum += $1 } END { if (NR > 0) print sum / NR }'

if [ $stage -le 1 ]; then

  if ! $continue_with_previous; then
    rm -r paragraph/processed_data &>/dev/null
  fi

  echo "Process data" # I need to do this differently. Otherwise the insertion of paragraphs will be way to slow
  utils/slurm.pl --mem 12G --time 0-2:00 $datadir/log/data.log \
    python paragraph/data.py ${datadir} || exit 1;
fi

if [ $stage -le 2 ]; then
  echo "Train the model"
  utils/slurm.pl --gpu 1 --mem 12G --time 0-10:00 $datadir/log/main.log \
    python paragraph/main.py $modeldir althingi_paragraph 256 0.02 || exit 1;
fi

if [ $stage -le 3 ]; then
  echo "Insert paragraph tokens into the dev and test sets using the 1st stage model"
  for dataset in dev test; do
    (
      utils/slurm.pl --mem 8G --time 0-10:00 ${datadir}/log/${dataset}_paragraphed.log \
        cat ${datadir}/althingi.$dataset.txt \| THEANO_FLAGS='device=cpu' python paragraph/paragrapher.py $modeldir/Model_althingi_paragraph_h256_lr0.02.pcl ${datadir}/${dataset}_paragraphed.txt || exit 1;
    ) &
  done
  wait
  #sbatch --export=datadir=$datadir,modeldir=$modeldir paragraph/local/run_paragrapher.sh
fi

if [ $stage -le 4 ]; then
  echo "Calculate the prediction errors"

  for d in dev test; do
    (
      python paragraph/error_calculator.py \
        ${datadir}/althingi.$d.txt \
        ${datadir}/${d}_paragraphed.txt \
        > ${datadir}/${d}_error.txt \
      || error 12 ${error_array[12]};
    ) &
  done
fi
