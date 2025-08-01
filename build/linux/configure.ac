dnl -----------------------------------------------------------------------
dnl Copyright: 2010-2022, imec Vision Lab, University of Antwerp
dnl            2014-2022, CWI, Amsterdam
dnl
dnl Contact: astra@astra-toolbox.com
dnl Website: http://www.astra-toolbox.com/
dnl
dnl This file is part of the ASTRA Toolbox.
dnl
dnl
dnl The ASTRA Toolbox is free software: you can redistribute it and/or modify
dnl it under the terms of the GNU General Public License as published by
dnl the Free Software Foundation, either version 3 of the License, or
dnl (at your option) any later version.
dnl
dnl The ASTRA Toolbox is distributed in the hope that it will be useful,
dnl but WITHOUT ANY WARRANTY; without even the implied warranty of
dnl MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
dnl GNU General Public License for more details.
dnl
dnl You should have received a copy of the GNU General Public License
dnl along with the ASTRA Toolbox. If not, see <http://www.gnu.org/licenses/>.
dnl
dnl -----------------------------------------------------------------------

AC_INIT([astra],[2.3.0])
AC_CONFIG_SRCDIR([Makefile.in])
LT_INIT([disable-static])

SAVED_CPPFLAGS="$CPPFLAGS"
SAVED_CXXFLAGS="$CXXFLAGS"
SAVED_NVCCFLAGS="$NVCCFLAGS"
SAVED_LDFLAGS="$LDFLAGS"
SAVED_LIBS="$LIBS"

AC_CANONICAL_BUILD
AC_CANONICAL_HOST

AC_PROG_CC
AC_PROG_CXX
AC_PROG_INSTALL
AC_PROG_MAKE_SET

AC_LANG([C++])

dnl Use iostream to check if the C++ compiler works
AC_CHECK_HEADER(iostream, , AC_MSG_ERROR([No working c++ compiler found]))


# boost-unit-test-framework

AC_MSG_CHECKING([for boost-unit-test-framework])

ASTRA_CHECK_BOOST_UNIT_TEST_FRAMEWORK(-lboost_unit_test_framework-mt, BOOSTUTF=yes_mt, BOOSTUTF=no)
HAVEBOOSTUTF=no
if test x$BOOSTUTF = xno; then
  ASTRA_CHECK_BOOST_UNIT_TEST_FRAMEWORK(-lboost_unit_test_framework, BOOSTUTF=yes, BOOSTUTF=no)
  if test x$BOOSTUTF = xno; then
    AC_MSG_RESULT(no)
  else
    AC_MSG_RESULT([yes, libboost_unit_test_framework])
    LIBS_BOOSTUTF="-lboost_unit_test_framework"
    HAVEBOOSTUTF=yes
  fi
else
  AC_MSG_RESULT([yes, libboost_unit_test_framework-mt])
  LIBS_BOOSTUTF="-lboost_unit_test_framework-mt"
  HAVEBOOSTUTF=yes
fi

AC_SUBST(HAVEBOOSTUTF)
AC_SUBST(LIBS_BOOSTUTF)

# nvcc, cuda

AC_ARG_WITH(cuda, [[  --with-cuda=path        path of CUDA (optional)]],,)

if test x"$with_cuda" != xno; then
  NVCC_PATH=$PATH
  if test x"$with_cuda" != x -a x"$with_cuda" != xyes; then
    NVCC_PATH="$with_cuda/bin:$NVCC_PATH"
  fi
  AC_PATH_PROG([NVCC], [nvcc], [no], [$NVCC_PATH])
else
  NVCC=no
fi

HAVECUDA=no
if test x"$NVCC" != xno; then
  HAVECUDA=yes
  BACKUP_CUDA_LDFLAGS="$LDFLAGS"
  if test x"$with_cuda" != x -a x"$with_cuda" != xyes; then
    test -d $with_cuda/lib64 && LDFLAGS_CUDA="-L$with_cuda/lib64" || LDFLAGS_CUDA="-L$with_cuda/lib"
    CPPFLAGS_CUDA="-I$with_cuda/include"
    LDFLAGS="$LDFLAGS $LDFLAGS_CUDA"
  fi
  AC_CHECK_LIB(cudart,cudaMalloc, ,HAVECUDA=no)
  AC_CHECK_LIB(cufft,cufftPlan1d, ,HAVECUDA=no)

  LIBS="$SAVED_LIBS"
  LDFLAGS="$BACKUP_CUDA_LDFLAGS"
  unset BACKUP_CUDA_LDFLAGS
  # TODO: check for cuda headers?

  AC_SUBST(NVCC)
fi

if test x"$HAVECUDA" = xyes; then
  AC_MSG_CHECKING([if nvcc works])
  ASTRA_CHECK_NVCC(HAVECUDA,NVCCFLAGS_EXTRA)
  AC_MSG_RESULT($HAVECUDA)
fi

AC_ARG_WITH(cuda_compute, [[  --with-cuda-compute=archs  list of compute models, or all/all-major/native (optional)]],,)
if test x"$HAVECUDA" = xyes; then
  AC_MSG_CHECKING([for nvcc archs])
  dnl 10 11 12 13 20 21 30 32 35 37 50 52 53 60 61 62 70 72 75 80 86 87 89
  dnl 90 90a 100 100a 101 101a 120 120a
  dnl
  dnl Build cubin for range of platforms, and ptx for newest for forward compat.
  dnl Build cubin x.0 for older platforms, and all x.y for "recent" ones.
  dnl
  dnl Include 3.5 since CUDA 11.x doesn't support 3.0, but does support 3.5.
  dnl (All other CUDA toolkits from 7-10 start support at x.0 versions.)
  dnl Skip 7.2 cubin since that seems to be Jetson-only (and can use 7.0 cubin).
  dnl
  dnl From CUDA Programming Guide:
  dnl "Binary compatibility is guaranteed from one minor revision to the next one, but not from one minor revision to the previous one or across major revisions."
  dnl

  NVCCARCHS_MAJOR=no
  if test x"$with_cuda_compute" = xall-major -o x"$with_cuda_compute" = xall -o x"$with_cuda_compute" = xnative -o x"$with_cuda_compute" = x; then
    nvcc_arch_option="$with_cuda_compute"
    if test x"$with_cuda_compute" = x; then
      nvcc_arch_option=all-major
    fi
    ASTRA_CHECK_NVCC_ARCH_OPTION([$nvcc_arch_option],NVCCARCHS_OPTION,NVCCFLAGS_EXTRA)

    if test x$NVCCARCHS_OPTION = xno; then
      if test x"$with_cuda_compute" != x; then
        AC_MSG_ERROR([requested arch flag ($with_cuda_compute) not supported])
      fi
    fi
  fi

  if test x$NVCCARCHS_OPTION = xyes; then
    AC_MSG_RESULT([$nvcc_arch_option])
  else
    if test x"$with_cuda_compute" = x; then
      with_cuda_compute="20,30,35,50,60,70,80,90,100,120"
    fi
    ASTRA_FIND_NVCC_ARCHS([$with_cuda_compute],NVCCFLAGS_EXTRA,NVCCARCHS)

    AC_MSG_RESULT([$NVCCARCHS])
  fi
fi

AC_ARG_VAR(NVCCFLAGS, [CUDA nvcc flags])

PKGCONFIG_CFLAGS_EXTRA=
if test x"$HAVECUDA" = xyes; then
  PKGCONFIG_CFLAGS_EXTRA="-DASTRA_CUDA"
fi
AC_SUBST(PKGCONFIG_CFLAGS_EXTRA)



AC_SUBST(HAVECUDA)
AC_SUBST(LDFLAGS_CUDA)
AC_SUBST(CPPFLAGS_CUDA)
AC_SUBST(NVCCFLAGS_EXTRA)


# AMD hip

AC_ARG_WITH(hip, [[  --with-hip=path         path of AMD HIP (optional)]],,)

dnl Currently we require this to be explicitly set, even if hipcc is in PATH
if test x"$with_hip" != xno -a x"$with_hip" != x; then
  HIPCC_PATH=$PATH
  if test x"$with_hip" != x -a x"$with_hip" != xyes; then
    HIPCC_PATH="$with_hip/bin:$HIPCC_PATH"
  fi
  AC_PATH_PROG([HIPCC], [hipcc], [no], [$HIPCC_PATH])
else
  HIPCC=no
fi

HAVEHIP=no
if test x"$HIPCC" != xno; then
  HAVEHIP=yes
  BACKUP_HIP_LDFLAGS="$LDFLAGS"
  if test x"$with_hip" != x -a x"$with_hip" != xyes; then
    test -d $with_hip/lib64 && LDFLAGS_HIP="-L$with_hip/lib64" || LDFLAGS_HIP="-L$with_hip/lib"
    CPPFLAGS_HIP="-I$with_hip/include"
    LDFLAGS="$LDFLAGS $LDFLAGS_HIP"
  fi
  AC_CHECK_LIB(amdhip64,hipMalloc, ,HAVEHIP=no)
  AC_CHECK_LIB(hipfft,hipfftPlan1d, ,HAVEHIP=no)

  LIBS="$SAVED_LIBS"
  LDFLAGS="$BACKUP_HIP_LDFLAGS"
  unset BACKUP_HIP_LDFLAGS
  # TODO: check for HIP headers?

  AC_SUBST(HIPCC)
fi

dnl Decide if there is specific functionality or any flag to test for hipcc
dnl if test x"$HAVEHIP" = xyes; then
  dnl AC_MSG_CHECKING([if hipcc works])
  dnl ASTRA_CHECK_HIPCC(HAVEHIP,HIPCCFLAGS_EXTRA)
  dnl AC_MSG_RESULT($HAVEHIP)
dnl fi

AC_SUBST(HAVEHIP)
AC_SUBST(LDFLAGS_HIP)
AC_SUBST(CPPFLAGS_HIP)

if test x"$HAVEHIP$HAVECUDA" = xyesyes; then
  AC_MSG_ERROR(NVIDIA CUDA and AMD HIP can currently not both be enabled)
fi


# mex, matlab

AC_ARG_WITH(matlab, [[  --with-matlab=path      path of Matlab (optional)]],,)

MEX_PATH=$PATH
HAVEMATLAB=no
if test x"$with_matlab" != x; then
  MEX_PATH="$with_matlab/bin:$MEX_PATH"
  AC_PATH_PROG([MEX], [mex], [no], [$MEX_PATH])
  if test x"$MEX" != xno; then
    HAVEMATLAB=yes
    # TODO: check platform of C compiler is same as mex
    AC_SUBST(MEX)
    MATLAB_ROOT="$with_matlab"
    AC_SUBST(MATLAB_ROOT)
    # TODO: maybe catch mex warnings
    ASTRA_CHECK_MEX_SUFFIX([mexa64 mexglx mexmaci64 mexmaci],[MEXSUFFIX])
    if test x$MEXSUFFIX = x; then
      AC_MSG_FAILURE([Unable to determine matlab mex suffix])
      HAVEMATLAB=no
    fi
    AC_SUBST(MEXSUFFIX)
  fi
fi

if test x"$HAVEMATLAB" = xyes; then
  AC_MSG_CHECKING([if mex requires the -R2017b option])
  ASTRA_CHECK_MEX_OPTION([-R2017b],[$MEXSUFFIX],[
    MEXFLAGS="-R2017b"
    # TODO: check if this is the best way of emulating -R2017b when using
    # CXX directly to compile mex files.
    CPPFLAGS_MATLAB="-DMATLAB_MEXCMD_RELEASE=700"
    AC_MSG_RESULT([yes])
  ],[
    MEXFLAGS=
    CPPFLAGS_MATLAB=
    AC_MSG_RESULT([no])
  ])
fi

AC_SUBST(HAVEMATLAB)
AC_SUBST(MEXFLAGS)
AC_SUBST(CPPFLAGS_MATLAB)

# octave

AC_ARG_ENABLE(octave, [[  --enable-octave         enable Octave support]])
if test x"$enable_octave" = xyes; then
  AC_PATH_PROG([HAVEOCTAVE], [octave-config], [no], [$PATH])
  AC_MSG_CHECKING([for octave])
  if test x"HAVEOCTAVE" != xno -a $HAVEMATLAB = yes; then
    HAVEOCTAVE=no
    AC_MSG_RESULT([no (since Matlab support is enabled)])
  else
    if test x"$HAVEOCTAVE" != xno; then
      OCTAVE_CPPFLAGS="-I`octave-config -p OCTINCLUDEDIR`"
      AC_SUBST(OCTAVE_CPPFLAGS)
      HAVEOCTAVE=yes
    fi
    AC_MSG_RESULT($HAVEOCTAVE)
  fi
else
  HAVEOCTAVE=no
fi
AC_SUBST(HAVEOCTAVE)

# python

AC_ARG_WITH(python, [[  --with-python=path      path of Python binary (optional)]],,)

HAVEPYTHON=no
if test x"$with_python" != x -a x"$with_python" != xno; then
  if test x"$with_python" = xyes; then
    PYTHON=python
  else
    PYTHON="$with_python"
  fi
  AC_MSG_CHECKING(for python)
  ASTRA_RUN_LOGOUTPUT(echo 'import sys' | $PYTHON -)
  if test $? -ne 0; then
    AC_MSG_ERROR(Python binary not found)
  fi
  AC_MSG_RESULT([$PYTHON])
  HAVEPYTHON=yes
  AC_SUBST(PYTHON)
  AC_MSG_CHECKING(for setuptools.build_meta)
  ASTRA_TRY_PYTHON([import setuptools.build_meta],,HAVEPYTHON=no)
  if test x$HAVEPYTHON = xno; then
    AC_MSG_RESULT(no)
    AC_MSG_ERROR(You need setuptools supporting build_meta to install the ASTRA toolbox for Python)
  fi
  AC_MSG_RESULT(yes)
  AC_MSG_CHECKING(for numpy module)
  ASTRA_TRY_PYTHON([import numpy],,HAVEPYTHON=no)
  if test x$HAVEPYTHON = xno; then
    AC_MSG_RESULT(no)
    AC_MSG_ERROR(You need the numpy module to use the ASTRA toolbox in Python)
  fi
  AC_MSG_RESULT(yes)
  AC_MSG_CHECKING(for Cython module)
  ASTRA_TRY_PYTHON([import Cython],,HAVEPYTHON=no)
  if test x$HAVEPYTHON = xno; then
    AC_MSG_RESULT(no)
    AC_MSG_ERROR(You need the Cython module to install the ASTRA toolbox for Python)
  fi
  AC_MSG_RESULT(yes)
  AC_MSG_CHECKING(for scipy module)
  ASTRA_TRY_PYTHON([import scipy],,HAVEPYTHON=no)
  if test x$HAVEPYTHON = xno; then
    AC_MSG_RESULT(no)
    AC_MSG_ERROR(You need the scipy module to use the ASTRA toolbox in Python)
  fi
  AC_MSG_RESULT(yes)
  AC_MSG_CHECKING(for tomli/tomllib modules)
  ASTRA_TRY_PYTHON([import tomllib],,HAVEPYTHON=no)
  if test x$HAVEPYTHON = xno; then
    ASTRA_TRY_PYTHON([import tomli],HAVEPYTHON=yes,HAVEPYTHON=no)
    if test x$HAVEPYTHON = xno; then
      AC_MSG_ERROR(You need the tomli or tomllib module to install the ASTRA toolbox for Python)
    fi
  fi
  AC_MSG_RESULT(yes)
fi

AC_SUBST(HAVEPYTHON)

#OS specific setup
AC_CANONICAL_HOST
case $host_os in
  darwin* )
        CXXFLAGS_OS="-stdlib=libstdc++ -mmacosx-version-min=10.6"
        LDFLAGS_OS="-stdlib=libstdc++"
        IS_MACOS=yes
        ;;
    *)
        CXXFLAGS_OS=""
        LDFLAGS_OS=""
        IS_MACOS=no
        ;;
esac

AC_SUBST(CXXFLAGS_OS)
AC_SUBST(LDFLAGS_OS)
AC_SUBST(IS_MACOS)

# For some reason, some older versions of autoconf produce a config.status
# that disables all lines looking like VPATH=@srcdir@
# (More recent autoconf fixes the too broad matching there.)
# We use a different variable name as a workaround.
VPATH_SRCDIR="$srcdir"
AC_SUBST(VPATH_SRCDIR)


# Installation type
AC_ARG_WITH(install-type, [[  --with-install-type=prefix|module|dir  type of installation (default prefix)]],,with_install_type=prefix)

INSTALL_TYPE=$with_install_type
AC_SUBST(INSTALL_TYPE)



# TODO:

# Detection of tools:
# libtool (how?)

# options:
# debugging/optimization/profiling flags


AC_SUBST(SAVED_CPPFLAGS)
AC_SUBST(SAVED_CXXFLAGS)
AC_SUBST(SAVED_NVCCFLAGS)
AC_SUBST(SAVED_LDFLAGS)
AC_SUBST(SAVED_LIBS)
AC_CONFIG_FILES([Makefile libastra.pc])
AC_OUTPUT

echo
echo "Summary of ASTRA Toolbox build options:"
echo "  NVIDIA CUDA: $HAVECUDA"
if test x$HAVEHIP = xyes; then
  echo "  AMD HIP    : yes (experimental!)"
fi
echo "  Matlab     : $HAVEMATLAB"
echo "  Octave     : $HAVEOCTAVE"
echo "  Python     : $HAVEPYTHON"
echo
echo "Installation type: $with_install_type"
case $with_install_type in
  prefix)
    echo   "  Library     : "$(eval echo `eval echo $libdir`)
    if test $HAVEMATLAB = yes; then
      echo "  Matlab files: "$(eval echo `eval echo $datadir`)"/astra/matlab"
    fi
    if test $HAVEOCTAVE = yes; then
      echo "  Octave files: "$(eval echo `eval echo $datadir`)"/astra/octave"
    fi
    if test $HAVEPYTHON = yes; then
      echo "  Python files to site-packages"
    fi
    ;;
  dir)
    echo   "  Library     : "$(eval echo `eval echo $libdir`)
    if test $HAVEMATLAB = yes; then
      echo "  Matlab files: $prefix/matlab"
    fi
    if test $HAVEOCTAVE = yes; then
      echo "  Octave files: $prefix/octave"
    fi
    if test $HAVEPYTHON = yes; then
      echo "  Python files: $prefix/python"
    fi
    ;;
  module)
    echo   "  Library into Matlab/Octave/Python module directories"
    if test $HAVEMATLAB = yes; then
      echo "  Matlab files: $prefix/matlab"
    fi
    if test $HAVEOCTAVE = yes; then
      echo "  Octave files: $prefix/octave"
    fi
    if test $HAVEPYTHON = yes; then
      echo "  Python files to site-packages"
    fi
esac
