# Continues an installer script once its base distribution is in place:
# installs the TeX Live packages Lattice requires. The script before it sets
# TEXBIN and TLMGR, and DISTRIBUTION_PACKAGES to what its base lacks, as a
# space-separated list.
CURRENT_STEP="Updating the TeX Live package manager"
status installing-packages
tlmgr_with_fallback update --self
# latexmk is intentionally not part of the BasicTeX base package. The
# collections and Type1 fonts cover Lattice's bundled conference templates;
# AAAI's style also needs newtx (whose map reads kastrup's binhex.tex), and
# the Chinese thesis classes need ctex with xeCJK and zhnumber, bibunits, and
# the XITS and STIX Two math fonts.
CURRENT_STEP="Installing the required LaTeX packages"
# shellcheck disable=SC2086 # DISTRIBUTION_PACKAGES is meant to split.
tlmgr_with_fallback install \
  latexmk \
  biber \
  texcount \
  collection-latexextra \
  collection-fontsrecommended \
  algorithms \
  algorithmicx \
  tex-gyre \
  helvetic \
  courier \
  times \
  psnfss \
  cmap \
  csquotes \
  newtx \
  kastrup \
  ctex \
  xecjk \
  zhnumber \
  bibunits \
  xits \
  stix2-otf \
  ${DISTRIBUTION_PACKAGES} 2>&1 | relay_progress installing-packages

if [[ -x "${TEXBIN}/updmap-sys" ]]; then
  CURRENT_STEP="Refreshing the TeX font maps"
  "${TEXBIN}/updmap-sys"
fi
