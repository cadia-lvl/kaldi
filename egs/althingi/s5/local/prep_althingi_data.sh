#!/bin/bash -e

set -o pipefail

# Copyright 2017  Reykjavik University (Author: Inga Rún Helgadóttir)
# Apache 2.0

# Get the Althingi data on a proper format for kaldi.

stage=-1
nj=10

. ./path.sh # Needed for KALDI_ROOT
. ./cmd.sh
. parse_options.sh || exit 1;

if [ $# -ne 2 ]; then
    echo "Usage: $0 <path-to-original-data> <output-data-dir>" >&2
    echo "Eg. $0 ~/data/local/corpus data/all" >&2
    exit 1;
fi

#datadir=data/local/corpus
#outdir=data/all
datadir=$(readlink -f $1); shift
outdir=$1; shift
mkdir -p $outdir

meta=${datadir}/metadata.csv

audiofile=$(ls ${datadir}/audio/ | head -n1)
extension="${audiofile##*.}"

# Need to convert from mp3 to wav
samplerate=16000
# SoX converts all audio files to an internal uncompressed format before performing any audio processing
wav_cmd="sox -t$extension - -c1 -esigned -r$samplerate -G -twav - "
#wav_cmd="sox -tflac - -c1 -esigned -twav - " # I had also files converted to flac that were already downsampled

if [ $stage -le 0 ]; then
    
    echo "a) utt2spk" # Connect each utterance to a speaker.
    echo "b) wav.scp" # Connect every utterance with an audio file
    for s in ${outdir}/utt2spk ${outdir}/wav.scp ${outdir}/filename_uttID.txt; do
        if [ -f ${s} ]; then rm ${s}; fi
    done

    IFS=$'\n' # Want to separate on new lines
    for line in $(LC_ALL=C sort ${meta})
    do
	filename=$(echo $line | cut -d"," -f6)
	spkID=$(echo $line | cut -d"," -f1 | perl -pe 's/[ \.]//g')

	# Print to utt2spk
	printf "%s %s\n" ${spkID}-${filename} ${spkID} | tr -d $'\r' >> ${outdir}/utt2spk

	# Make a helper file with mapping between the filenames and uttID
	echo -e ${filename} ${spkID}-${filename} | tr -d $'\r' | LC_ALL=C sort -n >> ${outdir}/filename_uttID.txt
	
	#Print to wav.scp
	echo -e ${spkID}-${filename} $wav_cmd" < "$(readlink -f ${datadir}/audio/${filename}".$extension")" |" | tr -d $'\r' >> ${outdir}/wav.scp
	#echo -e ${spkID}-${filename} $wav_cmd" < "$(readlink -f ${datadir}/audio/${filename}".flac")" |" | tr -d $'\r' >> ${outdir}/wav.scp
    done

    echo "c) spk2utt"
    utils/utt2spk_to_spk2utt.pl < ${outdir}/utt2spk > ${outdir}/spk2utt
fi

# NOTE! The following commented out section is for the case when I have new data that I need to fit to
# previously obtained data, where I used different speaker IDs.

# name_id_file=data/althingiUploads/spk_spkID.txt
# meta=data/althingiUploads/rad_spk.txt

# # Need to convert from mp3 to wav
# samplerate=16000
# # SoX converts all audio files to an internal uncompressed format before performing any audio processing
# wav_cmd="sox -tmp3 - -c1 -esigned -r$samplerate -G -twav - "

# if [ $stage -le 0 ]; then
    
#     echo "a) utt2spk" # Connect each utterance to a speaker.
#     echo "b) wav.scp" # Connect every utterance with an audio file
    
#     for s in ${outdir}/utt2spk ${outdir}/wav.scp ${outdir}/filename_uttID.txt; do
#         if [ -f ${s} ]; then rm ${s}; fi
#     done
#     IFS=$'\n' # Want to separate on new lines
#     for line in $(cat $meta)
#     do
#         filename=$(echo $line | cut -f1)
#         spkname=$(echo $line | cut -f2)
#         spkID=$(grep $spkname ${name_id_file} | cut -f2)

#         # Print to utt2spk
#         printf "%s %s\n" ${spkID}-${filename} ${spkID} | tr -d $'\r' >> ${outdir}/utt2spk

#         # Make a helper file with mapping between the filenames and uttID
#         echo -e ${filename} ${spkID}-${filename} | tr -d $'\r' | LC_ALL=C sort -n >> ${outdir}/filename_uttID.txt
        
#         #Print to wav.scp
#         echo -e ${spkID}-${filename} $wav_cmd" < "$(readlink -f ${datadir}/audio/${filename}".mp3")" |" | tr -d $'\r' >> ${outdir}/wav.scp
#     done

#     echo "d) spk2utt"
#     utils/utt2spk_to_spk2utt.pl < ${outdir}/utt2spk > ${outdir}/spk2utt
# fi

if [ $stage -le 1 ]; then

    echo "d) text" # Each line is utterance ID and the utterance itself
    for n in bb endanlegt; do
        utils/slurm.pl --time 0-06:00 $outdir/log/extract_text_${n}.log python3 local/extract_text.py $datadir/text_${n} $outdir/text_orig_${n}.txt &
    done
    
    # Extract the text in an xml file.
#     for n in bb endanlegt; do
#         export xmldir=${datadir}/text_${n} #text_bb
#         python -c "
# import glob
# import os
# import re
# xmlpaths = glob.glob(os.path.join(os.environ['xmldir'],'*.xml'))
# fout = open('${outdir}/text_orig_${n}.txt','w')
# for file in xmlpaths:
#     file_base = os.path.splitext(os.path.basename(file))[0]
#     with open(file, 'r',encoding='utf-8') as fin:
#         data=fin.read().replace('\n', ' ')
#         body_txt = re.search('<ræðutexti>(.*)</ræðutexti>',data).group()    
#     text = ' '.join([file_base, body_txt]).strip().replace('\n', ' ')
#     print(text, file=fout)
# fout.close()
# "
#     done
#     unset xmldir

fi

if [ $stage -le 2 ]; then

    echo "Remove xml-tags and comments"

    # In the following I separate the numbers on "|":
    # 1) removes comments on the form "<mgr>//....//</mgr>"
    # 2) removes comments on the form "<!--...-->"
    # 3) removes links that were not written like 2)
    # 4) removes f.ex. <mgr>::afritun af þ. 287::</mgr>
    # 5) removes comments on the form "<mgr>....//</mgr>"
    # 6-7) removes comments before the beginning of speeches
    # 8-11) removes comments like "<truflun>Kliður í salnum.</truflun>"
    # 12) removes comments in parentheses
    # 13) (in a new line) Rewrite fractions
    # 14-16) Rewrite law numbers
    # 17-19) Remove comments in a) parentheses, b) left: "(", right "/" or "//", c) left: "/", right one or more ")" and maybe a "/", d) left and right one or more "/"
    # 20) Remove comments on the form "xxxx", used when they don't hear what the speaker said
    # 21-22) Remove the remaining tags and reduce the spacing to one between words
    sed -re 's:<mgr>//[^/<]*?//</mgr>|<!--[^>]*?-->|http[^<> )]*?|<[^>]*?>\:[^<]*?ritun[^<]*?</[^>]*?>|<mgr>[^/]*?//</mgr>|<ræðutexti> +<mgr>[^/]*?/</mgr>|<ræðutexti> +<mgr>til [0-9]+\.[0-9]+</mgr>|<truflun>[^<]*?</truflun>|<atburður>[^<]*?</atburður>|<málsheiti>[^<]*?</málsheiti>: :g' \
        -e 's:\(+[^/()<>]*?\)+: :g' \
        -e 's:([0-9]) 1/2\b:\1,5:g' -e 's:\b([0-9])/([0-9]{1,2})\b:\1 \2\.:g' \
	-e 's:/?([0-9]+)/([0-9]+): \1 \2:g' -e 's:([0-9]+)/([A-Z]{2,}):\1 \2:g' -e 's:([0-9])/ ([0-9]):\1 \2:g' \
        -e 's:\(+[^/()<>]*?\)+: :g' -e 's:\([^/<>)]*?/+: :g' -e 's:/[^/<>)]*?\)+/?: :g' -e 's:/+[^/<>)]*?/+: :g' \
	-e 's:xx+::g' \
	-e 's:\(+[^/()<>]*?\)+: :g' -e 's:<[^<>]*?>: :g' -e 's:[[:space:]]+: :g' <${outdir}/text_orig_bb.txt > ${outdir}/text_noXML_bb.txt	

    sed -re 's:<!--[^>]*?-->|<truflun>[^<]*?</truflun>|<atburður>[^<]*?</atburður>|<málsheiti>[^<]*?</málsheiti>|<[^>]*?>: :g' \
        -e 's:\([^/()<>]*?\)+: :g' \
	-e 's:([0-9]) 1/2\b:\1,5:g' -e 's:\b([0-9])/([0-9]{1,2})\b:\1 \2\.:g' \
	-e 's:/?([0-9]+)/([0-9]+): \1 \2:g' -e 's:([0-9]+)/([A-Z]{2,}):\1 \2:g' -e 's:([0-9])/ ([0-9]):\1 \2:g' \
        -e 's:[[:space:]]+: :g' ${outdir}/text_orig_endanlegt.txt > ${outdir}/text_noXML_endanlegt.txt

    # Sometimes some of the intermediatary text files are empty.
    # I remove the empty files and add corresponding final-text-files in the end
    egrep -v "rad[0-9][^ ]+ *$" ${outdir}/text_noXML_bb.txt > tmp && mv tmp ${outdir}/text_noXML_bb.txt

    # Remove files that exist only in the intermediate text
    comm -12 <(cut -d" " -f1 ${outdir}/text_noXML_bb.txt | sort -u) <(cut -d" " -f1 ${outdir}/text_noXML_endanlegt.txt | sort -u) > ${outdir}/common_ids.tmp
    join -j1 ${outdir}/common_ids.tmp ${outdir}/text_noXML_bb.txt > tmp && mv tmp ${outdir}/text_noXML_bb.txt

fi


if [ $stage -le 3 ]; then
    
    echo "Rewrite roman numerals before lowercasing" # Enough to rewrite X,V and I based numbers. L=50 is used once and C, D and M never.
    # Might clash with someones middle name. # The module roman comes from Dive into Python
    for n in bb endanlegt; do
	sed -i -r 's/([A-Z]\.?)–([A-Z])/\1 til \2/g' ${outdir}/text_noXML_${n}.txt
	python3 -c "
import re
import sys
roman_path='/home/staff/inga/kaldi/egs/althingi/s5/local'
if not roman_path in sys.path:
    sys.path.append(roman_path)
import roman
text = open('${outdir}/text_noXML_${n}.txt', 'r')
text_out = open('${outdir}/text_noRoman_${n}.txt', 'w')
for line in text:
    match_list = re.findall(r'\b(X{0,3}IX|X{0,3}IV|X{0,3}V?I{0,3})\.?,?\b', line, flags=0)
    match_list = [elem for elem in match_list if len(elem)>0]
    match_list = list(set(match_list))
    match_list.sort(key=len, reverse=True) # Otherwise it will substitute parts of roman numerals
    line = line.split()
    tmpline=[]
    for match in match_list:
        for word in line:
            number = [re.sub(match,str(roman.fromRoman(match)),word) for elem in re.findall(r'\b(X{0,3}IX|X{0,3}IV|X{0,3}V?I{0,3})\.?,?\b', word) if len(elem)>0]
            if len(number)>0:
                tmpline.extend(number)
            else:
                tmpline.append(word)
        line = tmpline
        tmpline=[]
    print(' '.join(line), file=text_out)

text.close()
text_out.close()
"
    done
fi

if [ $stage -le 4 ]; then

    echo "Lowercase, rewrite and remove punctuations"
    # 1) Remove comments that appear at the end of certain speeches (still here because contained <skáletrað> in original text)
    # 2) Rewrite time,
    # 3) Change "&amp;" to "og"
    # 4-5) Remove punctuations which is safe to remove
    # 6) Remove "ja" from numbers written like "22ja",
    # 7) Rewrite [ck]?m[23] to [ck]?m[²³] and "kV" to "kw"
    # 8) Add missing space between sentences and fix spelling errors like "be4stu" and "o0g",
    # 9) Rewrite website names,
    # 10) In an itemized list, lowercase what comes after the numbering.
    # 11) Rewrite en dash (x96), regular dash and "tilstr(ik)" to " til ", if sandwitched between words or numbers,
    # 12) Rewrite decimals, f.ex "0,045" to "0 komma 0 45" and "0,00345" to "0 komma 0 0 3 4 5" and remove space before a "%",
    # 13 Rewrite vulgar fractions
    # 14) Remove "," when not followed by a number
    # 15) Remove final period (mostly to distinguish between numbers and ordinals) and period after letters,
    # 16) Lowercase text (not uttID) and rewrite "/a " to "á ári" and "/s " to "á sekúndu"
    # 17) Rewrite "/a " to "á ári", "/s " to "á sekúndu" and so on.
    # 18) Change dashes (exept in utt filenames) and remaining slashes out for space
    # 19) Rewrite thousands and millions, f.ex. 3.500 to 3500,
    # 20) Rewrite chapter and clause numbers and time and remove remaining periods between numbers, f.ex. "ákvæði 2.1.3" to "ákvæði 2 1 3" and "kl 15.30" to "kl 15 30",
    # 21) Add spaces between letters and numbers in alpha-numeric words (Example:1st: "4x4", 2nd: f.ex. "bla.3. júlí", 3rd: "1.-bekk."
    # 22) Fix spacing around % and degrees celsius and add space in a number starting with a zero
    # 23) Remove "lauk á fyrri spólu"
    # 24) Remove remaining punctuations (leaving the utt filenames intact) and weird words and fix spacing
    for n in bb endanlegt; do
        sed -re 's:\[(Þingmenn risu úr sætum[^]]*?)|(Strengjakvartett flutti lagið[^]]*?)\]: :g' \
            -e 's/([0-9]):([0-9][0-9])/\1 \2/g' \
            -e 's/&amp;/og/g' \
            -e 's:[^a-záðéíóúýþæöA-ZÁÉÍÓÚÝÞÆÖ0-9 \.,?!:;/%‰°º—–²³¼¾½ _-]+::g' \
            -e 's:\?|!|\:|;|,+ | ,+| \.+|,\.| |__+: :g' \
            -e 's:([0-9]+)ja\b:\1:g' \
            -e 's:([ck]?m)2: \1²:g' -e 's:([ck]?m)3: \1³:g' -e 's: kV : kw :g' -e 's:Wst:\L&:g' \
            -e 's: ([^ ]*[^ A-ZÁÐÉÍÓÚÝÞÆÖ])([A-ZÁÐÉÍÓÚÝÞÆÖ]): \1 \2:g' -e 's: ([a-záðéíóúýþæö]+)[0-9]([a-záðéíóúýþæö]+): \1\2:g' \
            -e 's:www\.:w w w :g' -e 's:\.(is|net|com|int)\b: punktur \1:g' \
            -e 's: +([0-9]\.) +([A-ZÁÐÉÍÓÚÝÞÆÖ]): \1 \L\2:g' \
            -e 's:([^ 0-9])–([^ 0-9]):\1 \2:g' -e 's:([^ ])–([^ ]):\1 til \2:g' -e 's:([0-9]\.?)tilstr[^ 0-9]*?\.?([0-9]):\1 til \2:g' -e 's:([0-9\.%])-+([0-9]):\1 til \2:g' \
            -e 's:([0-9]+),([0-46-9]):\1 komma \2:g' -e 's:([0-9]+),5([0-9]):\1 komma 5\2:g' \
	    < ${outdir}/text_noRoman_${n}.txt \
	    | perl -pe 's/ (0(?!,5))/ $1 /g' | perl -pe 's/komma (0? ?)(\d)(\d)(\d)(\d?)/komma $1$2 $3 $4 $5/g' \
            | sed -re 's:¼: einn 4. :g' -e 's:¾: 3 fjórðu:g' -e 's:([0-9])½:\1,5 :g' -e 's: ½: 0,5 :g' \
                  -e 's:,([^0-9]|$):\1:g' -e 's:([^0-9]),:\1 :g' \
                  -e 's:\.+( +[A-ZÁÐÉÍÓÚÝÞÆÖ]|$):\1:g' -e 's:([^0-9])\.+([0-9]):\1 \2:g' -e 's:([^0-9])\.+:\1:g' -e 's:([0-9]{4,})\.+:\1 :g' \
                  -e 's: .+:\L&:g' \
                  -e 's:/a\b: á ári:g' -e 's:/s\b: á sekúndu:g' -e 's:/kg\b: á kíló:g' -e 's:/klst\b: á klukkustund:g' \
                  -e 's:—|–|/|tilstr[^ 0-9]*?\.?: :g' -e 's:([a-záðéíóúýþæö])-+([a-záðéíóúýþæö]):\1 \2:g' \
                  -e 's:([0-9]+)\.([0-9]{3})\b\.?:\1\2:g' \
                  -e 's:([0-9]{1,2})\.([0-9]{1,2})\b:\1 \2:g' -e 's:([0-9]{1,2})\.([0-9]{1,2})\b\.?:\1 \2 :g' -e 's:([0-9]+)\.([0-9]+%?)\.?:\1 \2 :g' \
                  -e 's:( [0-9]+)([^0-9 ,.])([0-9]):\1 \2 \3:g' -e 's:( [a-záðéíóúýþæö]+)\.?-?([0-9]+)\b:\1 \2:g' -e 's:(^| )([0-9,]+%?\.?)-?([a-záðéíóúýþæö]+)\b:\1\2 \3:g' \
                  -e 's: *%:% :g' -e 's:([°º]) c :\1c :g' -e 's: 0([0-9]): 0 \1:g' \
		  -e 's:lauk á (f|fyrri) ?sp.*::' \
                  -e 's/[^a-záðéíóúýþæö0-9\., %‰°º²³T]+//g' -e 's/ [^ ]*[a-záðéíóúýþæö]+[0-9]+[^ ]*/ /g' -e 's:[0-9]{10,}:<unk>:g' -e 's/[[:space:]]+/ /g' \
                  > ${outdir}/text_noPuncts_${n}.txt
    done
fi

if [ $stage -le 5 ]; then
    echo "Expand some abbreviations, incl. 'hv.' and 'þm.' in certain circumstances"
    for n in bb endanlegt; do
	# Start with expanding some abbreviations using regex
        sed -re 's:\bamk\b:að minnsta kosti:g' \
	    -e 's:\bdr\b:doktor:g' \
	    -e 's:\betv\b:ef til vill:g' \
	    -e 's:\bfrh\b:framhald:g' \
	    -e 's:\bfyrrv\b:fyrrverandi:g' \
	    -e 's:\bheilbrrh\b:heilbrigðisráðherra:g' \
	    -e 's:\biðnrh\b:iðnaðarráðherra:g' \
	    -e 's:\binnanrrh\b:innanríkisráðherra:g' \
	    -e 's:\blandbrh\b:landbúnaðarráðherra:g' \
	    -e 's:\bmas\b:meira að segja:g' \
	    -e 's:\bma\b:meðal annars:g' \
	    -e 's:\bmenntmrh\b:mennta og menningarmálaráðherra:g' \
	    -e 's:\bmkr\b:millj kr:g' \
	    -e 's:\bnk\b:næstkomandi:g' \
	    -e 's:\bnr\b:númer:g' \
	    -e 's:\bnúv\b:núverandi:g' \
	    -e 's:\bosfrv\b:og svo framvegis:g' \
	    -e 's:\boþh\b:og þess háttar:g' \
	    -e 's:\bpr\b:per:g' \
	    -e 's:\bsbr\b:samanber:g' \
	    -e 's:\bskv\b:samkvæmt:g' \
	    -e 's:\bss\b:svo sem:g' \
	    -e 's:\bstk\b:stykki:g' \
	    -e 's:\btd\b:til dæmis:g' \
	    -e 's:\btam\b:til að mynda:g' \
	    -e 's:\buþb\b:um það bil:g' \
	    -e 's:\butanrrh\b:utanríkisráðherra:g' \
	    -e 's:\bviðskrh\b:viðskiptaráðherra:g' \
	    -e 's:\bþáv\b:þáverandi:g' \
	    -e 's:\bþús\b:þúsund:g' \
	    -e 's:\bþeas\b:það er að segja:g' \
	    < ${outdir}/text_noPuncts_${n}.txt > ${outdir}/text_exp1_${n}.txt
    done
       
    for n in bb endanlegt; do
        # Add spaces into acronyms pronounced as letters
	IFS=$'\n'
        for var in $(cat text_norm/abbr_acro_as_letters.txt | awk '{ print length, $0 }' | sort -nrs | cut -d" " -f2)
        do
	    var1=$(echo $var | sed 's/./& /g')
	    sed -i "s/\b$var\b/$var1/g" ${outdir}/text_exp1_${n}.txt
        done
        sed -r -i 's/[[:space:]]+/ /g' ${outdir}/text_exp1_${n}.txt

        # Capitalize acronyms which are pronounced as words
        # Make the regex pattern
        tr "\n" "|" < text_norm/acronyms_as_words.txt | sed '$s/|$//' | perl -pe "s:\|:\\\b\|\\\b:g" | sed 's:.*:\L&:' > text_norm/acronyms_as_words_pattern.tmp

         # Capitalize 
         srun sed -r 's:(\b'$(cat text_norm/acronyms_as_words_pattern.tmp)'\b):\U\1:g' ${outdir}/text_exp1_${n}.txt > ${outdir}/text_exp1_${n}_acroCS.txt
	
	# Use Anna's code to expand many instances of hv, þm og hæstv
	python3 local/althingi_replace_plain_text.py ${outdir}/text_exp1_${n}_acroCS.txt ${outdir}/text_exp2_${n}.txt
    done
fi

if [ $stage -le 6 ]; then
    
    echo "Fix spelling errors"
    cut -d" " -f2- ${outdir}/text_exp2_endanlegt.txt | sed -e 's/[0-9\.,%‰°º]//g' | tr " " "\n" | egrep -v "^\s*$" | sort -u > ${outdir}/words_text_endanlegt.txt
    if [ -f ${outdir}/text_bb_SpellingFixed.txt ]; then
	rm ${outdir}/text_bb_SpellingFixed.txt
    fi

    # Split into subfiles and correct them in parallel
    num_files=$nj
    mkdir -p ${outdir}/split${num_files}/log
    total_lines=$(wc -l ${outdir}/text_exp2_bb.txt | cut -d" " -f1)
    ((lines_per_file = (total_lines + num_files - 1) / num_files))
    split --lines=${lines_per_file} data/all_okt2017/text_exp2_bb.txt ${outdir}/split${num_files}/text_exp2_bb.

    source py3env/bin/activate
    IFS=$'\n' # Important
    for ext in $(ls ${outdir}/split${num_files}/text_exp2_bb.* | cut -d"." -f2); do
        srun --time=0-12 --nodelist=terra ./local/correct_spelling.sh $outdir $ext $num_files &>${outdir}/split${num_files}/log/spelling_fixed.${ext}.log &
    done
    deactivate

    cat ${outdir}/split${num_files}/text_bb_SpellingFixed.*.txt > ${outdir}/text_bb_SpellingFixed.txt
    rm -f ${outdir}/split${num_files}/{speech.*,vocab_speech_only.*,vocab_text_endanlegt_speech.*}

    # source py3env/bin/activate
    # IFS=$'\n' # Important
    # for speech in $(tail -n +7129 ${outdir}/text_exp2_bb_pruned.txt)
    # do
    #     uttID=$(echo $speech | cut -d" " -f1)
    # 	echo $speech | cut -d" " -f2- | sed -e 's/\b[0-9\.,%‰°º]+\b//g' | tr " " "\n" | egrep -v "^\s*$" | sort -u > vocab_speech.tmp
	
    # 	# Find words that are not in any text_endanlegt speech 
    # 	comm -23 <(cat vocab_speech.tmp) <(cat ${outdir}/words_text_endanlegt.txt) > vocab_speech_only.tmp
	
    # 	grep $uttID ${outdir}/text_exp2_endanlegt.txt > text_endanlegt_speech.tmp
    # 	cut -d" " -f2- text_endanlegt_speech.tmp | sed -e 's/[0-9\.,%‰°º]//g' | tr " " "\n" | egrep -v "^\s*$" | sort -u > vocab_text_endanlegt_speech.tmp

    # 	echo $speech > speech.tmp
    # 	# Find the closest match in vocab_text_endanlegt_speech.tmp and substitute
    # 	#set +u # Otherwise I will have a problem with unbound variables
    # 	python local/MinEditDist.py speech.tmp ${outdir}/text_bb_SpellingFixed.txt vocab_speech_only.tmp vocab_text_endanlegt_speech.tmp	
    # 	#set -u
    # done
    # deactivate
    rm *.tmp
    
fi

if [ $stage -le 7 ]; then

    # If the intermediate text file is empty or does not exist, use the final one instead
    egrep "^rad[0-9][^ ]+ *$" ${outdir}/text_bb_SpellingFixed.txt > empty_text_bb.tmp
    if [ -s empty_text_bb.tmp ]; then
	echo "Empty text_bb files"
	echo "Insert text from text_endanlegt"
	for file in $(cat empty_text_bb.tmp); do
	    sed -i -r "s#${file}#$(grep $file ${outdir}/text_exp2_endanlegt.txt)#" ${outdir}/text_bb_SpellingFixed.txt
	done
    fi

    # If the intermediate file did not exist at all, I use the final text instead
    comm -13 <(cut -d" " -f1 ${outdir}/text_bb_SpellingFixed.txt | sort -u) <(cut -d" " -f1 ${outdir}/text_exp2_endanlegt.txt | sort -u) > ${outdir}/ids_only_in_text_endanlegt.tmp
    join -j1 ${outdir}/ids_only_in_text_endanlegt.tmp ${outdir}/text_exp2_endanlegt.txt >> ${outdir}/text_bb_SpellingFixed.txt
    sort -u ${outdir}/text_bb_SpellingFixed.txt > tmp && mv tmp ${outdir}/text_bb_SpellingFixed.txt
    
    # Join the utterance names with the spkID to make the uttIDs
    join -j 1 <(sort -k1,1 ${outdir}/filename_uttID.txt) <(sort -k1,1 ${outdir}/text_bb_SpellingFixed.txt) | cut -d" " -f2- > ${outdir}/text_bb_SpellingFixed_uttID.txt
    
    if [ -e ${outdir}/text ] ; then
	# we don't want to overwrite old stuff, ask the user to delete it.
	echo "$0: ${outdir}/text already exists: "
	echo "Are you sure you want to proceed?"
	echo "It will overwrite the file"
	echo ""
        echo "  If so, please delete and then rerun"
	exit 1;
    fi

    cp ${outdir}/text_bb_SpellingFixed_uttID.txt ${outdir}/text
    
    echo "Make sure all files are created and that everything is sorted"
    utils/validate_data_dir.sh --no-feats ${outdir} || utils/fix_data_dir.sh ${outdir}
fi

IFS=$' \t\n'
exit 0
