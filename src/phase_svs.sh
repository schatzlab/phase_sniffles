#!/bin/bash

VCF2DIPLOIDJAR=/work-zfs/mschatz1/mschatz/build/vcf2diploid/vcf2diploid.jar

#set -xv
set -e

if [ $# -ne 6 ]
then
  echo "USAGE: phase_svs.sh phased_snps.vcf unphased_structural_variants.vcf long_reads.bam genome.fa outputprefix gender"
  exit
fi

BINDIR=`dirname $(readlink -f "$0")`
PHASEDSNPS=$1
STRUCTURALVARIANTS=$2
LONGREADSBAM=$3
GENOME=$4
OUTPREFIX=$5
GENDER=$6

echo "phase_svs.sh"
echo "  BINDIR: $BINDIR"
echo "  PHASEDSNPS: $PHASEDSNPS"
echo "  STRUCTURALVARIANTS: $STRUCTURALVARIANTS"
echo "  LONGREADSBAM: $LONGREADSBAM"
echo "  GENOME: $GENOME"
echo "  GENDER: $GENDER"
echo 
echo "  OUT: $OUTPREFIX"
echo
echo

## Sanity check parameters

if [[ $GENDER != "male" && $GENDER != "female" ]]
then
  echo "Unknown gender: $GENDER"
  exit
fi

if [ ! -r $GENOME ]
then
  echo "Cannot read genome file: $GENOME"
  exit
fi

if [ ! -r $LONGREADSBAM ]
then
  echo "Cannot read long reads bam file: $LONGREADSBAM"
  exit
fi

if [ ! -r $STRUCTURALVARIANTS ]
then
  echo "Cannot read sv vcf file: $STRUCTURALVARIANTS"
  exit
fi

if [ ! -r $PHASEDSNPS ]
then
  echo "Cannot read phased snp file: $PHASEDSNPS"
  exit
fi

## Sanity checks passed, begin analysis

GENOME=`readlink -f $GENOME`
AS=$OUTPREFIX.alleleseq
VCFID=`head -5000 $PHASEDSNPS | grep '#CHROM' | awk '{print $10}'`

if [ ! -r $OUTPREFIX.hairs ]
then
  echo "extracting pacbio-hairs from phased snps (mbq 0)"
  extractHAIRS --mbq 0 --bam $LONGREADSBAM --VCF $PHASEDSNPS --out $OUTPREFIX.hairs
fi

if [ ! -r $OUTPREFIX.scrubbed.vcf ]
then
  echo "Scrubbing SV calls"
  ($BINDIR/scrubvcf.pl $STRUCTURALVARIANTS > $OUTPREFIX.scrubbed.vcf) >& $OUTPREFIX.scrubbed.log
fi

if [ ! -r $OUTPREFIX.spliced.vcf ]
then
  echo "Splicing in phased SVs"
  $BINDIR/splicephase.pl $PHASEDSNPS $OUTPREFIX.scrubbed.vcf $OUTPREFIX.hairs $OUTPREFIX.spliced.vcf $GENOME >& $OUTPREFIX.spliced.log
fi

if [ ! -r $OUTPREFIX.spliced.vcf.gz ]
then
  echo "compressing spliced vcf"
  pigz -k $OUTPREFIX.spliced.vcf
fi

if [ ! -r $AS ]
then
  mkdir -p $AS
  cd $AS

  echo "constructing diploid sequence with SNPs and SVs"
  java -Xmx400000m -jar $VCF2DIPLOIDJAR -id $VCFID -pass -chr $GENOME -vcf ../$OUTPREFIX.spliced.vcf >& vcf2diploid.log
  cd ..
fi

if [ ! -r $AS.raw.tgz ]
then
  echo "tarring up alleleseq"
  tar czvf $AS.raw.tgz $AS
fi

if [ ! -r $AS/raw/ ]
then
  echo "renaming files"

  cd $AS

  mkdir -p raw
  mkdir -p raw/attic

  for i in `ls *_$VCFID*`
  do 
    echo " $i"
    mv $i $OUTPREFIX.$i
  done

  rename _$VCFID '' *_$VCFID*

  rename paternal hap1 *paternal*
  rename maternal hap2 *maternal*

  rename _hap1 .hap1 *_hap1*
  rename _hap2 .hap2 *_hap2*

  mv hap1.chain raw/$OUTPREFIX.hap1.chain
  mv hap2.chain raw/$OUTPREFIX.hap2.chain

  mv $OUTPREFIX.chrM.hap2.fa raw/attic

  if [[ $GENDER == "male" ]]
  then
    echo "male sample, making X and Y haploid"
    mv *chrX.hap2.fa *chrY.hap2.fa raw/attic
    cat raw/$OUTPREFIX.hap1.chain                                   | sed 's/paternal/hap1/' > $OUTPREFIX.hap1.chain
    $BINDIR/removechain.pl raw/$OUTPREFIX.hap2.chain chrM chrX chrY | sed 's/maternal/hap2/' > $OUTPREFIX.hap2.chain
  else
    echo "female sample, stashing Y chromosome"
    mv *chrY* raw/attic
    $BINDIR/removechain.pl raw/$OUTPREFIX.hap1.chain chrY           | sed 's/paternal/hap1/' > $OUTPREFIX.hap1.chain
    $BINDIR/removechain.pl raw/$OUTPREFIX.hap2.chain chrM chrY      | sed 's/maternal/hap2/' > $OUTPREFIX.hap2.chain
  fi

  echo "fixing map files"
  for i in `/bin/ls *.map`
  do
    echo " $i"
    mv $i raw/
    sed 's/PAT/HAP1/' raw/$i | sed 's/MAT/HAP2/' > $i
  done

  echo "fixing chromosome files"
  for i in `/bin/ls *hap1.fa`
  do
    echo " $i"
    mv $i raw/
    sed 's/paternal/hap1/' raw/$i > $i
  done

  for i in `/bin/ls *hap2.fa`
  do
    echo " $i"
    mv $i raw/
    sed 's/maternal/hap2/' raw/$i > $i
  done

  cd ..
fi

if [ ! -r $AS/$OUTPREFIX.hap1.fa.gz ]
then
  echo "Making final diploid genome"
  cat `ls $AS/*.chr*.hap1.fa | sort -V` > $AS/$OUTPREFIX.hap1.fa &
  cat `ls $AS/*.chr*.hap2.fa | sort -V` > $AS/$OUTPREFIX.hap2.fa &

  wait

  echo "compressing genome files"
  pigz $AS/$OUTPREFIX.hap1.fa
  pigz $AS/$OUTPREFIX.hap2.fa
fi

