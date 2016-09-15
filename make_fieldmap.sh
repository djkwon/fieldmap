#!/bin/bash
# 20160925: Created by Dongjin Kwon

dicom_dir=$1
out_dir=$2

if [ $# -ne 2 ]; then
  echo "usage: bash make_fieldmap.sh <dicom_dir> <out_dir>"
  exit 0
fi

module unload fsl
module unload afni
module unload cmtk

module load fsl
module load afni
module load cmtk

tmpdir=$(mktemp -d)

echo "Converting dicom images..."

echo dcm2image --xml --ignore-acq-number --tolerance 1e-3 -O ${tmpdir}/image%n.nii.gz ${dicom_dir}
dcm2image --xml --ignore-acq-number --tolerance 1e-3 -O ${tmpdir}/image%n.nii.gz ${dicom_dir}

echo "Checking inputs..."

mag_idx=0
real_idx=0
imag_idx=0
for idx in 1 2 3 4 5 6; do
  if [ ! -e ${tmpdir}/image${idx}.nii.gz ]; then
    continue
  fi

  type=`fgrep type ${tmpdir}/image${idx}.nii.gz.xml | sed 's/\s*<[^<]*>\s*//g'`
  echo_time=`fgrep dicom:EchoTime ${tmpdir}/image${idx}.nii.gz.xml | sed 's/\s*<[^<]*>\s*//g'`

  if [ "${type}" == "magnitude" ]; then
    mag_array[${mag_idx}]=${tmpdir}/image${idx}.nii.gz
    let mag_idx++
  elif [ "${type}" == "real" ]; then
    real_array[${real_idx}]=${tmpdir}/image${idx}.nii.gz
    echo_array[${real_idx}]=${echo_time}
    echo echo_time=${echo_time}
    let real_idx++
  elif [ "${type}" == "imaginary" ]; then
    imag_array[${imag_idx}]=${tmpdir}/image${idx}.nii.gz
    let imag_idx++
  fi
done

echo ${mag_idx}, ${real_idx}, ${imag_idx}

if [ ${mag_idx} -ne 2 ] || [ ${real_idx} -ne 2 ] || [ ${imag_idx} -ne 2 ]; then
  echo "ERROR: dicom data is incomplete."
  rm -rf ${tmpdir}
  exit 1
fi

echo "Brain stripping..."

magnitude_brain_mask=${tmpdir}/magnitude_brain_mask.nii.gz
imagemath --in ${mag_array[0]} ${mag_array[1]} --average --out ${tmpdir}/magnitude_average.nii.gz
bet ${tmpdir}/magnitude_average ${tmpdir}/magnitude_brain -m -f 0.5 -g -0.0
fslmaths ${tmpdir}/magnitude_brain_mask -kernel boxv 3 -ero ${magnitude_brain_mask}
cp -p ${tmpdir}/magnitude_brain.nii.gz ${out_dir}/magnitude_brain.nii.gz

echo "Calculate phasemap..."

phasemap_unwrapped=${tmpdir}/phasemap_unwrapped.nii.gz

imagemath --in ${real_array[0]} ${imag_array[0]} ${real_array[1]} ${imag_array[1]} --complex-div --out ${tmpdir}/fmap_i.nii.gz --pop --out ${tmpdir}/fmap_r.nii.gz

afni 3dcalc -a ${tmpdir}/fmap_r.nii.gz -b ${tmpdir}/fmap_i.nii.gz -expr 'atan2(b,a)' -prefix ${tmpdir}/fmap_p.nii.gz
afni 3dcalc -a ${tmpdir}/fmap_r.nii.gz -b ${tmpdir}/fmap_i.nii.gz -expr 'sqrt(a^2+b^2)' -prefix ${tmpdir}/fmap_m.nii.gz

fsl prelude -a ${tmpdir}/fmap_m.nii.gz -p ${tmpdir}/fmap_p.nii.gz -u ${phasemap_unwrapped} -m ${magnitude_brain_mask} -f

echo "Calculate fieldmap..."

fieldmap=${out_dir}/fieldmap.nii.gz
delta_te_sec=`python -c "print abs(${echo_array[0]} - ${echo_array[1]})/1000.0"`

if [ "$(awk -vn1=${delta_te_sec} 'BEGIN{print (n1!=0)?1:0 }')" -eq 1 ]; then
  fslmaths ${phasemap_unwrapped} -div ${delta_te_sec} ${fieldmap} -odt float
  fugue --loadfmap=${fieldmap} -m --savefmap=${fieldmap}
else
  echo "ERROR: delta_te_sec = ${delta_te_sec}. Cannot compute fieldmap."
  rm -rf ${tmpdir}
  exit 1
fi

rm -rf ${tmpdir}
exit 0

