BINDIR=$1
OUTDIR=$2
bamFile=$3
fastaFile=$4
for filename in `ls $OUTDIR/cert/*.cert`; do
    for ((i=0; i<=3; i++)); do
        if [ ! -f $filename'.done' ]; then
            nfilename="${filename##*/}"
            nfilename=${nfilename::${#nfilename}-5}
	        echo 'Rerunning (serial): '$nfilename
            timeout 2m "${BINDIR}"/process.sh $OUTDIR'/inserts/'$nfilename $BINDIR $OUTDIR $bamFile $fastaFile
        fi
    done
done
