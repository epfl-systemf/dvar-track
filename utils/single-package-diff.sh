set -xe

PKG_DIR1="/home/marvin/epfl/dummy-emacs-d/transient-20240629.1508"
PKG_DIR2="/home/marvin/epfl/dummy-emacs-d/transient-20251020.1535"
INIT_DIR="/home/marvin/epfl/dummy-emacs-d"

PKG_VER1=$(basename $PKG_DIR1)
PKG_VER2=$(basename $PKG_DIR2)

if [ "$PKG_VER1" = "$PKG_VER2" ]; then
    echo "error: two packages seems to have the same version"
    exit 1
fi

ls $PKG_DIR1
ls $PKG_DIR2

mv "$PKG_DIR1" "${INIT_DIR}/elpa/"
PKG_DIR="${INIT_DIR}/elpa/${PKG_VER1}" RECORD_FILE="${PKG_VER1}.el" RECORD_SCC_FILE="${PKG_VER1}-scc.el" emacs --init-directory="$INIT_DIR" -l single-package-diff.el --kill

mv "${INIT_DIR}/elpa/${PKG_VER1}" ${PKG_DIR1}

mv "$PKG_DIR2" "${INIT_DIR}/elpa/"
PKG_DIR="${INIT_DIR}/elpa/${PKG_VER2}" RECORD_FILE="${PKG_VER2}.el" RECORD_SCC_FILE="${PKG_VER2}-scc.el" emacs --init-directory="$INIT_DIR" -l single-package-diff.el --kill

mv "${INIT_DIR}/elpa/${PKG_VER2}" ${PKG_DIR2}
