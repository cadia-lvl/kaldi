#!/bin/bash -e

# Expand abbreviations and numbers in the texts to use for training and testing.

set -o pipefail

nj=50
stage=-1
order=5

echo "$0 $@"  # Print the command line for logging

. ./cmd.sh
. ./path.sh
. utils/parse_options.sh
. local/utils.sh

if [ $# != 3 ]; then
    echo "Usage: local/expand.sh [options] <text-norm-dir> <input-text-file> <output-text-file>"
    echo "e.g.: local/expand.sh text_norm data/all/text_bb_SpellingFixed.txt data/all/text"
    echo "or"
    echo "e.g.: local/expand.sh text_norm ~/data/althingi/pronDict_LM/scrapedAlthingiTexts_clean.txt ~/data/althingi/pronDict_LM/scrapedAlthingiTexts_expanded.txt"
fi

normdir=$1
infile=$2
outfile=$3
dir=$(dirname $infile);
mkdir -p ${dir}/split$nj/

if [ $stage -le 1 ]; then
    echo "We want to process it in parallel."
    IFS=$' \t\n'
    split_text=$(for j in `seq 1 $nj`; do printf "${dir}/split%s/cleantext.%s.txt " $nj $j; done)
    # The upper condition applies to the ASR training/testing texts and
    # the lower one applies to the LM training texts.
    if grep -q "rad[0-9]" ${infile}; then
        utils/split_scp.pl $infile $split_text # the field separator has to be correct
    else
	# I need to add IDs to get the utterances on a Kaldi format
	awk '{printf("%010d %s\n", NR, $0)}' $infile > ${dir}/cleantext_wID.txt
	utils/split_scp.pl ${dir}/cleantext_wID.txt $split_text
    fi
fi

if [ $stage -le 2 ]; then
    echo "Make a list over all the words in numbertexts if necessary"
    if [ ! -f ${normdir}/words_numbertexts_althingi100.txt ]; then
        gzip -cd ${normdir}/numbertexts_althingi100.txt.gz | cut -d" " -f2- | tr " " "\n" | grep -v "^\s*$" | sort -u > ${normdir}/words_numbertexts_althingi100.txt
    elif [ ${normdir}/words_numbertexts_althingi100.txt -ot ${normdir}/numbertexts_althingi100.txt.gz ]; then
	gzip -cd ${normdir}/numbertexts_althingi100.txt.gz | cut -d" " -f2- | tr " " "\n" | grep -v "^\s*$" | sort -u > ${normdir}/words_numbertexts_althingi100.txt
    fi
fi

if [ $stage -le 3 ]; then
    echo "Extract words that are only in the althingi texts, excluding unexpanded abbrs and numbers."
    echo "Map words which are not seen in context in numbertexts to <word>."
    for i in `seq 1 $nj`; do
	cut -d" " -f2- ${dir}/split${nj}/cleantext.${i}.txt | tr " " "\n" | grep -v "^\s*$" | sort -u > ${dir}/split${nj}/words_cleantext.${i}.tmp
	# Extract words that are only in the althingi texts, excluding unexpanded abbrs and numbers
	comm -23 <(comm -23 ${dir}/split${nj}/words_cleantext.${i}.tmp ${normdir}/words_numbertexts_althingi100.txt | egrep -v "[0-9]") <(cut -f1 ${normdir}/lex/abbr_lexicon.txt | sort -u) > ${dir}/split${nj}/words_job${i}_only.tmp
    done

    # Map words which are not seen in context in numbertexts to <word>
    utils/slurm.pl JOB=1:$nj ${dir}/split${nj}/log/save-OOVwords.JOB.log python3 local/save_OOVwords.py ${dir}/split${nj}/cleantext.JOB.txt ${dir}/split${nj}/words_jobJOB_only.tmp ${dir}/split${nj}/cleantext_afterWordMapping.JOB.txt ${dir}/split${nj}/mappedWords_jobJOB.txt
    # I get problems if encounter more than one space between words after the thrax step. Temporary fix is this:
    for i in `seq 1 $nj`; do
	sed -r -i 's: (%|\.):\1:g' ${dir}/split${nj}/cleantext_afterWordMapping.${i}.txt
    done
fi

if [ $stage -le 4 ]; then
        echo "Expand"
	utils/slurm.pl JOB=1:$nj ${dir}/log/expand-numbers.JOB.log expand-numbers --word-symbol-table=${normdir}/words30.txt ark,t:${dir}/split${nj}/cleantext_afterWordMapping.JOB.txt ${normdir}/expand_to_words30.fst ${normdir}/numbertexts_althingi100_${order}g.fst ark,t:${dir}/split${nj}/text_expanded_${order}g.JOB.txt
	# Old command
	#utils/slurm.pl JOB=1:$nj ${datadir}/log/expand-numbers.JOB.log expand-numbers --word-symbol-table=text_norm/text/words30all.txt ark,t:${datadir}/split${nj}/text_bb_SpellingFixed_noOOV.JOB.txt text_norm/expand_to_words30all.fst text_norm/text/numbertextsAll_3g.fst ark,t:${datadir}/split${nj}/text_expanded.JOB.txt &

fi

if [ $stage -le 5 ]; then

    echo "Insert words back"

    # The following is too slow. Need to fix!
    utils/slurm.pl JOB=1:$nj ${dir}/log/re-insert-oov.JOB.log local/re-insert-oov.sh ${dir}/split${nj}/text_expanded_${order}g.JOB.txt ${dir}/split${nj}/mappedWords_jobJOB.txt
    
    echo "Check if all the speeches were expanded"
    join -1 1 -2 1 <(egrep "[0-9]{10} $" ${dir}/split${nj}/text_expanded_${order}g.*.txt | sed 's/ *//g' | sort) <(sort ${dir}/split${nj}/cleantext_afterWordMapping.*.txt) > ${dir}/split${nj}/text_notexpanded_${order}g.txt
    # Ignore lines which were not expanded
    grep -vFwf <(cut -d" " -f1 ${dir}/split${nj}/text_notexpanded_${order}g.txt) ${dir}/split${nj}/text_expanded_${order}g.*.wOOV.txt | sort -u ${dir}/split${nj}/text_expanded_${order}g_wOOV.txt

    if [[ ! -z ${dir}/split${nj}/text_notexpanded_${order}g.txt ]]; then
	n=$(cat ${dir}/split${nj}/text_notexpanded_${order}g.txt | wc -l)
	echo $n" lines were empty after expansion\n"
	echo "they can be viewed in ${dir}/split${nj}/text_notexpanded_${order}g.txt"
        exit 1;
    else
	echo "All speeches were expanded :)"
    fi
    
    # echo "Check if all the speeches were expanded"
    # for j in `seq 1 $nj`; do

    # 	wait;
    # 	# Check if all the speeches were expanded
    # 	num_speeches_expanded=$(cut -d" " -f2- ${dir}/split${nj}/text_expanded_${order}g.$j.txt | egrep -v "^\s*$" | sort -u | wc -l | cut -d" " -f1)
    # 	num_speeched_total=$(wc -l ${dir}/split${nj}/cleantext_afterWordMapping.$j.txt | cut -d" " -f1)

    # 	if [ "$num_speeches_expanded" -eq "$num_speeched_total" ] ; then
    #         # Insert words back
    # 	    utils/slurm.pl ${dir}/split${nj}/log/re-inserting-OOVwords.$j.log python3 local/re-inserting-OOVwords.py ${dir}/split${nj}/text_expanded_${order}g.$j.txt ${dir}/split${nj}/mappedWords_job${j}.txt ${dir}/split${nj}/text_expanded_wOOV_${order}g.$j.txt
    # 	    # Insert line breaks, such that each line starts with an ID. In the case of the
    # 	    # LM model training text, I also remove the IDs.
    # 	    if grep -q "rad[0-9]" ${dir}/split${nj}/text_expanded_wOOV_${order}g.$j.txt; then 
    # 		sed -i -r 's: ([^ ]+rad[0-9]):\n\1:g' ${dir}/split${nj}/text_expanded_wOOV_${order}g.$j.txt
    # 	    else
    # 		sed -i -re 's: ([0-9]{10}):\n\1:g' -e 's:[0-9]{10} ::g' ${dir}/split${nj}/text_expanded_wOOV_${order}g.$j.txt
    # 	    fi
      
    # 	else
    #         echo "Some speeches in ${dir}/split${nj}/cleantext_afterWordMapping.$j.txt were not expanded!"
    # 	    echo "That has to be fixed before re-inserting the OOV words."
    #         exit 1;
    # 	fi
    # done
    # echo "OK!"
fi

if [ $stage -le 6 ]; then
    # # Put all expanded text into one file
    # if [ -f ${dir}/text_expanded_${order}g.txt ]; then
    # 	mv ${dir}/{,.backup/}text_expanded_${order}g.txt
    # fi
    # cat ${dir}/split${nj}/text_expanded_wOOV_${order}g.*.txt > ${dir}/text_expanded_${order}g.txt

    if [ -e ${outfile} ] ; then
	# we don't want to overwrite old stuff, ask the user to delete it.
	echo "$0: ${outfile} already exists: "
	echo "Are you sure you want to proceed?"
	echo "It will overwrite the file"
	echo ""
	echo "  If so, please delete and then rerun this part"
	exit 1;
    else
	cp ${dir}/split${nj}/text_expanded_${order}g_wOOV.txt ${outfile}
    fi
fi

exit 0;

# # Check if all the speeches were expanded
# num_speeches_expanded=$(cut -d" " -f2- ${datadir}/text_bb_expanded.txt | egrep -v "^\s*$" | sort -u | wc -l | cut -d" " -f1)
# num_speeched_total=$(wc -l ${datadir}/utt2spk | cut -d" " -f1)

# if [ "$num_speeches_expanded" -eq "num_speeched_total" ] ; then
#     cp ${datadir}/text_bb_expanded.txt ${datadir}/text
# else
#     echo "Some speeches were not expanded!"
#     exit 1;
# fi

# ################################
# #### Just a temporary fix ####
# grep -o "[^0-9 ]*_rad20[0-9]*T[0-9]*" ${datadir}/log/expand-numbers.*.log | cut -d":" -f2 | sort -u > ${datadir}/speeches_notExpanded.txt # Find speeches not expanded

# # Obtain the text NOT expanded
# if [ -f ${datadir}/text_bb_NOT_expanded.txt ]; then
#    rm ${datadir}/text_bb_NOT_expanded.txt
# fi

# for uttID in $(cat ${datadir}/speeches_notExpanded.txt)
# do
#     grep $uttID ${datadir}/text_bb_SpellingFixed.txt >> ${datadir}/text_bb_NOT_expanded.txt 
# done
# cat ${datadir}/text_bb_NOT_expanded.txt \
#         | utils/sym2int.pl --map-oov "<unk>" -f 2- text_norm/text/words30.txt \
#         | utils/int2sym.pl -f 2- text_norm/text/words30.txt > ${datadir}/text_bb_NOT_expanded.txt
# mv ${datadir}/text_bb_NOT_expanded.txt ${datadir}/text_bb_NOT_expanded.txt

# # Put all expanded text into one file
# #cat ${datadir}/text_expanded.*.txt > ${datadir}/text_bb_expanded.txt
# # Remove uttID of speeches not expanded. (Directly modify the file and create a backup)
# for uttID in $(cat ${datadir}/speeches_notExpanded.txt)
# do
#     sed -i.bak "/$uttID/d" ${datadir}/text_bb_expanded.txt
# done

# # Expand the not expanded again. I fixed the problem
# nj=2
# mkdir -p ${datadir}/split${nj}/
# split_text=$(for j in `seq 1 $nj`; do printf "${datadir}/split%s/text_bb_NOT_expanded.%s.txt " $nj $j; done)
# IFS=$' \t\n' # Important
# utils/split_scp.pl ${datadir}/text_bb_NOT_expanded.txt $split_text
# # Expand
# utils/slurm.pl JOB=1:$nj ${datadir}/log/expand-numbers_temp.JOB.log expand-numbers --word-symbol-table=text_norm/text/words30all.txt ark,t:${datadir}/split${nj}/text_bb_NOT_expanded.JOB.txt text_norm/expand_to_words30all.fst text_norm/text/numbertextsAll_3g.fst ark,t:${datadir}/split${nj}/text_expanded_try3.JOB.txt &

# ####################################

# egrep -o "key [0-9]{10}" ${dir}/log/expand-numbers.*.log | cut -d":" -f2 | cut -d" " -f2 | sort -u > ${dir}/split${nj}/uttIDs_notExpanded_${order}g.txt
# join -1 1 -2 1 ${dir}/split${nj}/uttIDs_notExpanded_${order}g.txt <(cat ${dir}/split${nj}/cleantext.*.txt | sort -k1,1) > ${dir}/split${nj}/text_notExpanded_${order}g.txt
