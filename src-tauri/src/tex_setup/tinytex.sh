# Continues installer-prelude.sh as the signed-in user, once Lattice has
# unpacked TinyTeX into the home folder. tex-packages.sh follows it.
TEXBIN=__TEXBIN__
TLMGR="${TEXBIN}/tlmgr"
# What TinyTeX lacks that BasicTeX ships with (synctex, xetex), and the
# Fandol fonts ctex uses outside macOS.
DISTRIBUTION_PACKAGES="synctex xetex fandol"

# The log stays private, but TeX's own files are installed readable.
umask 022

if [[ ! -x "${TLMGR}" ]]; then
  echo "TinyTeX was unpacked, but ${TLMGR} is missing."
  false
fi
