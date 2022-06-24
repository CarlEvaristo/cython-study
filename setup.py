import setuptools
import numpy
from distutils.core import setup
from Cython.Build import cythonize
setup(ext_modules=cythonize("RUN.pyx", build_dir="build"),
                                           script_args=['build'],
                                           options={'build':{'build_lib':'.'}},
                                           include_dirs=[numpy.get_include()])    # BELANGRIJKE REGEL ALS JE NUMPY EN CYTHON GEBRUIKT



# import setuptools
# from distutils.core import setup
# from Cython.Build import cythonize
# setup(ext_modules=cythonize("RUN.pyx", build_dir="build"),
#                                            script_args=['build'],
#                                            options={'build':{'build_lib':'.'}})



